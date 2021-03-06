#!/bin/bash
# Usage: grade dir_or_archive [output]

# Ensure realpath 
realpath . &>/dev/null
HAD_REALPATH=$(test "$?" -eq 127 && echo no || echo yes)
if [ "$HAD_REALPATH" = "no" ]; then
  cat > /tmp/realpath-grade.c <<EOF
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char** argv) {
  char* path = argv[1];
  char result[8192];
  memset(result, 0, 8192);

  if (argc == 1) {
      printf("Usage: %s path\n", argv[0]);
      return 2;
  }
  
  if (realpath(path, result)) {
    printf("%s\n", result);
    return 0;
  } else {
    printf("%s\n", argv[1]);
    return 1;
  }
}
EOF
  cc -o /tmp/realpath-grade /tmp/realpath-grade.c
  function realpath () {
    /tmp/realpath-grade $@
  }
fi

INFILE=$1
if [ -z "$INFILE" ]; then
  CWD_KBS=$(du -d 0 . | cut -f 1)
  if [ -n "$CWD_KBS" -a "$CWD_KBS" -gt 20000 ]; then
    echo "Chamado sem argumentos."\
         "Supus que \".\" deve ser avaliado, mas esse diretório é muito grande!"\
         "Se realmente deseja avaliar \".\", execute $0 ."
    exit 1
  fi
fi
test -z "$INFILE" && INFILE="."
INFILE=$(realpath "$INFILE")
# grades.csv is optional
OUTPUT=""
test -z "$2" || OUTPUT=$(realpath "$2")
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
# Absolute path to this script
THEPACK="${DIR}/$(basename "${BASH_SOURCE[0]}")"
STARTDIR=$(pwd)

# Split basename and extension
BASE=$(basename "$INFILE")
EXT=""
if [ ! -d "$INFILE" ]; then
  BASE=$(echo $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\1/g')
  EXT=$(echo  $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\2/g')
fi

# Setup working dir
rm -fr "/tmp/$BASE-test" || true
mkdir "/tmp/$BASE-test" || ( echo "Could not mkdir /tmp/$BASE-test"; exit 1 )
UNPACK_ROOT="/tmp/$BASE-test"
cd "$UNPACK_ROOT"

function cleanup () {
  test -n "$1" && echo "$1"
  cd "$STARTDIR"
  rm -fr "/tmp/$BASE-test"
  test "$HAD_REALPATH" = "yes" || rm /tmp/realpath-grade* &>/dev/null
  return 1 # helps with precedence
}

# Avoid messing up with the running user's home directory
# Not entirely safe, running as another user is recommended
export HOME=.

# Check if file is a tar archive
ISTAR=no
if [ ! -d "$INFILE" ]; then
  ISTAR=$( (tar tf "$INFILE" &> /dev/null && echo yes) || echo no )
fi

# Unpack the submission (or copy the dir)
if [ -d "$INFILE" ]; then
  cp -r "$INFILE" . || cleanup || exit 1 
elif [ "$EXT" = ".c" ]; then
  echo "Corrigindo um único arquivo .c. O recomendado é corrigir uma pasta ou  arquivo .tar.{gz,bz2,xz}, zip, como enviado ao moodle"
  mkdir c-files || cleanup || exit 1
  cp "$INFILE" c-files/ ||  cleanup || exit 1
elif [ "$EXT" = ".zip" ]; then
  unzip "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.gz" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.bz2" ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.xz" ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "yes" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "no" ]; then
  gzip -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "yes"  ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "no" ]; then
  bzip2 -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "yes"  ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "no" ]; then
  xz -cdk "$INFILE" > "$BASE" || cleanup || exit 1
else
  echo "Unknown extension $EXT"; cleanup; exit 1
fi

# There must be exactly one top-level dir inside the submission
# As a fallback, if there is no directory, will work directly on 
# tmp/$BASE-test, but in this case there must be files! 
function get-legit-dirs  {
  find . -mindepth 1 -maxdepth 1 -type d | grep -vE '^\./__MACOS' | grep -vE '^\./\.'
}
NDIRS=$(get-legit-dirs | wc -l)
test "$NDIRS" -lt 2 || \
  cleanup "Malformed archive! Expected exactly one directory, found $NDIRS" || exit 1
test  "$NDIRS" -eq  1 -o  "$(find . -mindepth 1 -maxdepth 1 -type f | wc -l)" -gt 0  || \
  cleanup "Empty archive!" || exit 1
if [ "$NDIRS" -eq 1 ]; then #only cd if there is a dir
  cd "$(get-legit-dirs)"
fi

# Unpack the testbench
tail -n +$(($(grep -ahn  '^__TESTBENCH_MARKER__' "$THEPACK" | cut -f1 -d:) +1)) "$THEPACK" | tar zx
cd testbench || cleanup || exit 1

# Deploy additional binaries so that validate.sh can use them
test "$HAD_REALPATH" = "yes" || cp /tmp/realpath-grade "tools/realpath"
cc -std=c11 tools/wrap-function.c -o tools/wrap-function \
  || echo "Compilation of wrap-function.c failed. If you are on a Mac, brace for impact"
export PATH="$PATH:$(realpath "tools")"

# Run validate
(./validate.sh 2>&1 | tee validate.log) || cleanup || exit 1

# Write output file
if [ -n "$OUTPUT" ]; then
  #write grade
  echo "@@@###grade:" > result
  cat grade >> result || cleanup || exit 1
  #write feedback, falling back to validate.log
  echo "@@@###feedback:" >> result
  (test -f feedback && cat feedback >> result) || \
    (test -f validate.log && cat validate.log >> result) || \
    cleanup "No feedback file!" || exit 1
  #Copy result to output
  test ! -d "$OUTPUT" || cleanup "$OUTPUT is a directory!" || exit 1
  rm -f "$OUTPUT"
  cp result "$OUTPUT"
fi

if ( ! grep -E -- '-[0-9]+' grade &> /dev/null ); then
   echo -e "Grade for $BASE$EXT: $(cat grade)"
fi

cleanup || true

exit 0

__TESTBENCH_MARKER__
�      �=kw۶���_�0�Kʒ���]�um%��cgc�g-_Z�,n$�!)�i��g?�O���v�CrRǽ��qrL��� 01����k�|�Ԁ�������FC}��M���P��&�7[�͍o���c)M�(vBB�q&�ƍ������8����'�Wт����F��$e��:t��h�b����}������v�Ҹ���������څ�]8Ѹ���ޛ�Ӟ����YjV^�=�u�����;�����;d�WqG�,1R�I���xL=(�OH}D�T�!t0���I�`���?�O	z�Ƥ�^F. W���3圙'&�FȰ��4�&K	�����}��:�({�"hTX����{Ns����^��1���^2�����vn�o���C���7�̆�|�C�_�VԬ��.�yÉ{�����`V��b����2Y�W�0�kd 3JLc'���S?�3�q�*@��c ai0q
���8T�p3�9��z��p�1-�CG���0���z&�p��AR!�\Y�7i�L,$O:�-31�T<2�w�sI�ɳ�$v��{F�:k�Cm+��,�H���Vx� C�!��|�j�����;:��*��8��}%o�է�*>GAIp��pX!q"�׈$ʋ�t��\N�I�F"�W�dgYV���2ص5���Y��,�� ZEAZ�~Ӷ�j��N!p����e�K@���f��6��dp���L��٬��M�g2�,�"�Y�6ϭ�[KҊJ��g	��@�J�ty � 3>�IKj$�0��5n���ad����~��6?՝T�YN�09MQ�Cd��_��]Z(״���T8�2GrH+"BI�����y��ݫ�g��®�WyfQ^�_�V��P�~�<��o�U��OƓb�>C�e#�L�j5'bf�aF0��V��e�~&�YV:�/��'�	u�YP�YLi2���}b���/;z���[	�6-|�>H��g�1�h�-�tP"r=�a���]��}�v�5yœa���$P����:���N	�s���\2�#�s�Cau��d%5Iw)պe^y-��,�i��;SU4�!ؤ���ݥ�ȹ�8iyPO%��	yք��AT��j0�T�B�2_�o� �����xA�@
� ��D>1G�3���=i�m��n?�c�n'w	��N/���PÛy�}ew�u�����q����qT^�?$��� ��	�8�=l(n*g �����t ������	$��)��_�"�0{��s��g�1lK�T�4�(D�qs�JFhEF~��.�А�Q���O=�v�A������e<F
1�L ��v{�k�Ѱ��r���w��2j�3�5�@נ!Z��ڭL9�"�����&~D�F�r�DS?o!�@�׆�J,��Ƒ�Xu2-2���d�������XL5O_H)�&]Ga�OF�A&���ɏq�ĚZ.�L�F�Y4V�<#=$VyC�}2tb�\;�j�ӘoPF���X�!Jv��J<�2�gA�LB}7���.�7u���M�L%Wjs��% QI8Qp��3w�@�R�MH�k�&4DL�w�ʊʾ�3kk07�?�~��!��O1La�we��BV	��	RG�����:��1�51L^	W;����ʟԏj�T��~��l��Kwx4�H��ɷ�owrp	�+!�3D;_�6�+��:�[��Y����� T�`B@�H�@V:�쟬17�`w���r��P�E4�!ڈ��ɺ߮{R�uU�]Y������Ҿk#(%���Ƥ��1�BS�y�	�Ś0�lCpZˎ�z@Q ����]�y��S�$��K�����ćH�r���M�_�U�URv��2t��~����ձ����ʝ�n�o5��"��o���{���,�*�'�{��6�a���,�W^v�?����Yڨ����G�%�k��'	�ڐ^�y�ɤR��Qli4��Ё!e�GtELn?��;���dR��d�WQ�I�;�^�	U4���v�;�I��/[	`,�퉓=��/q��$2̓�#%Y-lr��ї�AVp��$Y�0b].? ��G��:S��FJ�ĺ^�[xE �I�!�Xy|��8�� Z��.��?������؝R6!�(���}<^��lJ6�WWW!��L�҃���N$v'�%�=������)�;��+���J'��s��,���
�/J�t �aOE-�àҋ����|#��w��HNM*�UH�qc?"Cp�b?2r4��[L�ˇ�"�O��Gne�Ra��I�_(�����)/ixu,���[��s���� I��+���t�w=�#loU*,���8	�����F��L�p��Z������Wh���Ɍ(^8��()܀��qq*���\ڸ��|� �Mb�ͅ����N�9+.9�鋜�yf��$'��4��Z3����!~�:<���?��U�w�0�?���ӧO���4��� ���H�ԇ��:������8 �z	jl��[_ �=>`UĎ;A��%Ӕ�+M˒��Y8���yu{��V��w-�TR�b�^�Pl�-	��KG�}>���N��T�����l�_޼�4R��X��������0�cK�j��*�p;��X���Ǡ	����c,��%���dT !����2�H6�����ʗ�1EJ�\^�-YGuJ�$�߸� �r��z�!�7��I�Ƴ�֨o���\]&c�{��by�!�t1��'n��b
�����,�K���F���M�d �Z�wɷ�Z��X[���2Ȯf(*�~�H��1�5�?K�����c��C������;tb?�'y��{�c~�g�����o4�?$=uGސ��m�m���`�w���uO{?v������Sk@�@�ѡN�����v �e�Y����a�~�(��ک\����a���'��PΓ��4�p�
1��k��8x�C�pS�aN|�QٟiDQ!I/�	P`|6���HЁ��~p͎�P?cl�̋�K&��T)��� �(Gd>4��D��v�G�3*��3��_{0OgrO_�VA��s�Y�-<k�C�+�=����rGI�*sl8`o1�c7s(������7��U���#gL�d������iVHՒױ�"$Y�/�y6۳c�7��e���A��Z��O��j��?Q	��F��Օl豨 ō�3�.Ə�e�;��l�,�_���V-59յG�~����A�l��s�?�[[���C��Ӵ�����NC/{��3��f��z�ԉ��O�-�(�XtG�O���x�>�?��ך��Sw���"�x���|@��żs��	��{���B�LK��RsY�VeE50�!اo�����(�Ρ�;�)�ۣ�R�,>!#� c�S��=�E����ʜ�2a���y�d��];�b�i̼yTҹ�@�`V�ğ��'\'桹�6wqvR��vԈ9�'�ۍ�@������y�N�V�# G׊aj�u'���i2Tǜ ���0o�z�D��"�C�h+��JC�%y:^���j4w!�ʉ9��f�3ꬄY�$�M�7oe("�aMc8z}�N${�.�J�O��[��¹s;/�s#K�Eޝ�61��,CH��7�E�'�d`cŋQ��@MьTd,��р,u�'�d�bk�+���-��̋��z��<�6� �@�	�0�E�dȥq��A�"��0�=i�m�V�EK�dE+ڜ;-Ҵ��"��BH�CX���Et�16�f�ōH�/V��UC�����d|�,�����XIm-�k�	�6���%���O�3Ro��=O��E�d(+M-�]�'�P[#�Ȋ9'����&/o��h� Jƥu<�he�L+;�9��EwPS�rN^c��� �@%��'�R3�+7W��8s�����;�������a��T	K�9��"�:��*wW����:e�3i|�Y���`Ko���&\Vq^n��M��D�H>)��/��I�j�Y-%m5�JF85�]�(��c��m+�6r���N����s�K/��8g�ڹ�b�K6�D�٭7��Yk�� ��/N�&�|���-��s<�S_�#ពȭd�o.^�O5��,�Y���m,�eFօ}6@�Ծ�1�l�{}r|�;9>ܯ`B�-!]��H;���t��'Pp{;�%���k1�,h 
��b؄���ʆ.!��yD�]�&�
X�p'�!i����Tq��Z[=_�ICJ:��Ψ�"cb��t�
\WaK_�
19��|]�]-D.��/؋x]Y� `9��}Ͽh��D=��5-8`��M�8�^��0֨e�����O{ǯ����_��}� ��@�u��_��{D;���ޝ"j��@d������L�n(~/h���\]ϟa� �ۉgy6���)H|5�e(��m.Gh�r�Qx�CH>����U�	V�D���o_�|�~��~�$�C�=g��Sx��p_,)���L��1�"�c�]��t|+5+�	� a%�9����ru�?������B�q�	i��!�|ȦxY&ڪ�py]w�Qdz�;f�Ͼ���M���v��j�FZ��v=��V�F�V�[���{��kd}u��>6M|�^l᣹�.H��6Z �^}�n���F[Ϸ��W7�o��:4�����h��!�v�+����\��&Jx����?�Ub�N	�����|UA������\���\]���r��<x|��Wۀ��i<���=�B���F=ޙxĮ$������:�����Gl�p�5�ޔFD��߿ͫ*b�W��H/��`f� ��=j�kW�E�Tٓ�$ b�@^����m��������ۻ�*׋��u�J:pj�uۊ� �O���E���I5ؕ�����4E7���E�g��-������*�|�	�j�_���dؚ=ND������]f�ޔ�H�~�ۆI�P?�7ꃳƹ���0>jx�O�g�j#P"�msY��ܞ[$��>gV�e�\�
�\B�x���2��X��?P��5�h�k��^ڼ�Tt��x�O��ڛ���?�7�<H*��K�����4�J�q��=Svt�K(��S��l�N��Aw�5��\�"}��stwBj��� ��:�- K�AŬ�G���`�mg��4���Ĺ�C��`�N)z���S����tMl�FO��N{q-#�0��;qH�y�d��v�h���XW؟\
���)ǚG���a��9�(����ݑ�H��7���3z���� �(����($��LTL�� 
V��᮴���X���_����S'bK��	3_O��\�-�<�GE�IW�/"�Ih��w��)��;�S���.Mbכ�Eb���$~�`rD%é@���ƈ�^�3�6��, 9��{��j�h���%,�0�E���t{ߑ�E����~��:���V.�����ã����Sr@c:��ȍb:u��j�3p}�6���Ŏ�D�8 S~���1���kg`U���~�{`��nw�̓S���я�d/���7��#������~�a��ϛ�ӁzdU��T��g�W�;2Ro c�����z��,WS2X�f�u��(?�����r�G�G�� ����F�ɛ�1�t�� �
S0uc�֖��U����Ɲ%�* �j��OT*�>�֞}`_N����UM�!���ONN��y_+}k�������9:����E��}yڱ�w�]���7����ω�����{�>=y�v��i5�/��ڎ0��l�_=:ͳ����_x�o�}��776��C������Oo�{����Eۓ'jhfƤ�wȳ��!���������a���t��^�^�Q❭U��9ȩ0TC���oM��8���yeK��`�m�Ƞq@dV����k�Y�㶑�����Vf�yH�kO��(���V���sNv���$�3��ȉ��|�ڭ�W���?v��@�1��d}���l4�F��8��B�F��I/n6�y{w�	��������]T ť�K����w�]�=�6ɵf��?�9'A��'�CN����
���N����8�ͅ�Ob�"��攀P5�0��[��G��#}����9lp��ZE��Lx�lУ��P$�v(�%�ae-K�ȕ��kH0W������F�Q�c��ٽ�w�",C����
T����0R��Љ�EZX�04������Q�㔝��E��P��5WG{	1M�QmM?����RվETD�t;Ģ��f�����'O?]ά�Of���RloɊUWV����_/<�
���Ԝ���>t`V��a�*h[!v�_����Oa��Ft	�*����+jEB�V�~"�S3��B�?	#X�ӧ��2"JA*^�Z}��G����	\��I��i(�=�4��4+��I��n)]��- �{����9$2��p͇�SS�j������+�\�*a�*U�&�*������MW^�6��ǿ(P�H��hq"� ��t���H&}��ԋsk"&����̓��޻!��Ʌp����k��چ��_[���S����w��z���P�7��8��4j�y�b��SrXr��[?8�ق-��DV��{��I����;������箒�+�� 
��Ba����d�M�1��s*L�R�:�!�t�!���;�������g������못ba�s0�8$ّ�w'Q؅�w9պy���e�b	<:U��>W��MN�g�{܏ȁ�we�^俕{0�P6w[���գ��XYcv�A��y��Y_�{���)u��I�����5:	��G;p%}����
���)'S�D6�?"�����d�a�6A�X:�Ơ�?�%���'�C|��ʽ/��wB��o�ǰ�o�D�"����@�XN+ilճ
c)1A�R��wOu�T��U�)�E�i�Y6��b�v#!�H���G�jt�_N�=ģ�s)6e�R�ض��`�;�/����@� NM��<�P8��ɜ(��H�`��O�[c6O�+�DA�*�0��po�����"m[��Z�5%������v!��QE*�Σy3C)O?�~�vE�ľ]-T{*w2��`G�f�]@��Tl�&��(K�94��C�J�H���Wj�	�Y��M1;�d�`�j��� 6TҁJ���VƆn��
��V%�W�U�0��k�c)�i�:��ne�D[71VR���aV�d�8���N�L9΍e���{q�̾�"�M�]�~\$��^�`݅Ԯk��4��j����jY�U���>^���D�^\D�6ZƵ���|4��ڍ1ht-�!-۪\X�����]���e�|a}�x�R���ZM��B��e�Nď3Q�ȓ^�0x�9�9��Ҋ�=UL�3�ǯ��^�;W�h،M,�Q5�@��@����.�B#Fu�FRDq#�K�mln���zc��aE�|�*C������-���B���σ����6��E�Z������~&l<L���.0_mm����ut|���֦ E���r��J�Q$�8R|H����]���~�Hְ�0&�_��O��LS���gb�Z\J).�YR���{<8[6��4�޺t��I#�{u���Ζh���Ӯ�����ULuc94HX���%�x��au���}t]D����Ǎ���2΂�ɑӖ=ҵ�E2����:��\wճ�쥮O79��q3A�͓i�}��ܦ	����2�Zc��_��E90h��\<����+V���H� ��^GN��\e�u�Tb��J�Rԓ��b�ۙ��B[�~��o���V[� �G�
ry�x�bUӧ�
�K�ءA����]U�lA�v�is�L�>�Z�'�ō�3[>��xux���-=�@%,/s:	��6�Ķ;��ɏ������I�x7���������*�D�Pu��-5�F-J����7����
������;��.��J�T`l5�<]a��Gc�p�#�*�d����M�ㅻ�t���nc�	]�=
 wУ��r��r�T�L6�U���c�:�x'�BE���g*�K���2>$�7���� �f�A�X�A��&ҧP�M���t4�-�̂2܁�RE�hD�4���n�b���V�z\h��Up��q��l�X�1+��Z�y���P��T�(mJ2���m�AeR�#�4�
R����m��J�%�l>�Ŏ�,j�E�&��~�^��ӄ�i���9�8� �a�[��	.k9����Ͳ���E�Rɥ�)���n�����me��ɀIP�,#(�J5L�c/��R�]"���BfAe�珔�-���sf�A[V5�4I\����~����kU~��,�J���|�d�7�ҙV'D
��u��%�$'�W�E=�e������֑�%#g�F�����ø���f
�L}�?9����0n�ɞ��Æ��%aG8p�X0t���s���*�Y�@b���!��:Ê%�i���`l�d����W����̜�-�tEj��#RRA_��M�^[;�3�1I�
Enf���M"�y�e�z�U��w/�W��ъ�x[�]�gn�Ξ�$gm�͠,�U@i���풯��ܚ�ej���x�"�hӆ(X�r}��l��c ���c���0?h&;t���T�O�G�.>$�uU&�~-������*BӖ^[T�G�\c)Ր��Y���*����cI�GK�a��Y�˞�d��ŷ
�"�UV��$u��f�����25�^��4�yi����Lߪ��ekAj�Ojl.�Rvڛ)ھ�-�����BSS-4�݃�|�^S7'�8��{i�m�q���)�}�8a�<	K!Y�|1O��⻿UR��a����K�E/�rp�����%{c)٦b<R�/k%���*a\9Uy��Gi������)~�\�(>�fI�Z��N��>�yY�t�>�������^4��p
f�1�0�։� �k�4,_B?~S���������{U�W��@�5�}�,�ʱo���-mך|@iM��kMƻ�wS�V�>0����>���@�uV�z�y��5�"�5���������w�w��n�r�Lr��z����C|Pk5��I"�ۍf}<5Obq�g���튝i��s�������7���>�v`&�,��Ui�z�aJ͵�¤Z��\גotͳ�r�%o���r�����<�b|3����u
@g��^<5z�V���A�&�?s	�����~���8��$��q��#q�0�dQz�n�4T��M
�-ꬪ
ӽv1gY��%��,LR���K����a��)1�a�z�Rl~�e��x�".=�6���	Sخ(�H>`h��~ad nKd�C�^��q0�j� S�{!��N�1�(=��4�'D+_ �r��20m)��$�wdTe�9�'ヱ$�T*^ܖ~)�j`�֒�L���P6�~�O6bm��+Q�f�GG�N=��h���	_-a�"J|*<��$˘�K@�����O ��#p������8q�.Y[_�:��BN(���sI���y�W�
*^�S+$B��Q�O�O�Tt��[o�GA���M����7+���Mt�>P��V�:�{(������j0~ ��,面괙+�Ȳ�ײ��Zױ��w��ڄW� O�r�M�]����C
Vc�G=P���\���a"���U"a3SW^�(?��W�䑘-v�.�%��H:}Lf!�� SP��s ��J:�ܘ�Ҭ���*�ݘ<��RT��T�iǴ�<�8)P������pܾ�츏�ߟ��$����<�l���Su�e����v��3����*��!l�0d�p��O��	v�-�V�RgIN*���@~��c�"3CQ�`]�Re4
�50��䴨8D��Og�ԼN�H�S|%��b8�P�0�1�;`��Ii���nSq�5��T�Lz�Iȿ%�fR���V�<���	Gn��q�H���x{wks��q2���*lQ3;�rnMI8��� �ʕ)�O��lE�ʍz���\�޻	&t����9UdA��Â���6��
���� PR_PZ�ib�p�1t����3�Y3���\�|����wS�c�"��e͚�&�hg}�L^��S����I�q��Ǳz6zV�%]i#yn��G��&�3o�'��<�Q�m�c��C�!�o�9,o 짪	�rNZ��\�Q.��Dp^��9�o���ɩ��f��t�8���^�2C����\��<�jԵ���ELY�>hb'���h��yX(��{$��42!6�j!p��0��&�`D�O�w0�$���,rU��~�����U��3@�<�А��~xg�֫���!�3Qw�����y;e&���&���}��U2����WkwJ���\sP�Aȉ�"�7��T|��`v_�8ޘ+��<�:+�sE�h����ة�Z���&>�O��}�#����eY��-�����M$c��/9;L��9e΂S�S��sv��ϕ����5����m'+j;�gPڶX��{�����|�oU��=�[�(N�rӰ�����i����ť���?���w�z���ս��������}C����{�x�����뽰����^P��LR�J�07�(*-퓲�f��4�6l.�$�*I��h���x[��0��WW�E�Ћ�� ZNA���Li�轤���E�X���w��n�$��?���"]a��H��D���������\ [RY�]���Uy���\2�E��:������>��T�Ҭ������K(���dޕ������Y�dJ��37 ���?|�Y��,����(�W����]���h��fߣT�Y�r�%�����X��wvj=��C@zgM���J.9���
�b���L�a�IJ����Q���qhW/«#a��e��I{��-�Jޠ*a֎�c���3�(R+�j�j��[�[��b3��������������7���,k�3�g����AJo����k�l�޾���c�˜�krz��g]�0u��ќ��	!w�LB�~���(§��(A��N��{���1*�p����k
w��^4�znb��9b(��KS/�Ř�A���j������ca����'�fe1�x<����KnX��7D��ٺ��Ht��k�n�RG����g�� g��
"���I�ߋְ�N��p��m��+1��EمL�\�$á&j�-�ӿ��^���iu�Q|�m��X���"����P���u޺xq�ͷQ<�K���e���l�o�l��Yy��g٬���:���?��[����������F�h����������cޤ�	{������k��5标��X{���;5��w`�{���f�k4���z{����<������n���5g0� ����]kt�Q�����:>xu�&,�/��p�j�[/�����j��l+�0i����^Di��w�ơ�`#�'�0q��9��"�X��.th �`w@�
���NB�����,��l48-� ���#y��Ш�$����#�(z��躀��lUOa�� i�}��A�#� ���uz����H�ON8r�oF��������%�����w�sx_��	M�{��n�錜A;�{�& ��n��¨�.����$ڂr~����뻡����0$b�v�ٽ/X{ww�w ��`'o8��[�����������:�{����n�8���k�@}'��N�Y�jk}s��x~K?���n�&�.���"v��o �(ǡ�GD`�pj"�h(NF�7��;p���;uޓ; N��7��֣���8&������-�r��#�����/�
td����4���5o�~' �E_uhsYa� f���w�4<�&W� !��j�v����!��X{��5`,7���'�Yw�^t��p-|}�~�{�jo�x{���_���Ie�)j!;����Ȯl������~���_mb=���������
w���v�=1��w�����㭍��޾����vĖ��/��j�6�����rY�`��,�L��l� ϔ�9��	C�����y! ����!^��YQJ�X��a�﨤Ә�<a�s�@��]�jwԑ���<���lY�o����4]��F����T�g{(K/��5y���1q����IJ�3��zq��G,�1؃MNF^���)���=g������'yiAu\�����$s+�|��7k������Y�f�Vx�x���E6D���S�^�}8�a�D<�eѿH�7rm�g+0�V��+����c����?t�!:�2�_b/��(XAɀ�'!�P$a6���ȡ@�J��eB3���'rh���/��uP�s�Eȫ%�:z�s����x���� ш]�����wap�U���{�OD��/4�~����#lH ?
��/�]���(�����8��>Si�S�u������w��{0���u�2��߳�
��~���&_��~��~x���i6������AC1�,��Z�0|&jw
`�y�
�����-�l�_��v��@�ak��}[�s'Q���0�[��岁���cm�}u�[J�.���3�)��M��'e�k�̓�#����X"p��(�F4@����;�챢�ӉVL@���'��կ(H@$oy
R�C��L������p��Ü#��^�.���CΑAΫ�y�#�)�?�q�i*��&�u���w���"�bCjw��B�/�Q���[���^�&]l�	�;g�~9�0ce#@��Q_�+ylG�0MG���oT	�A�|�/��h���J�ҩ��f+�;_�t2�������GK�߱�/��t0����C�-Uw����H{�8�'���n���4�%t%]j��ӵΗ�q�[�>z��f�=	iy���ϝ�N��7;���I3�j��C�pP(tY�F8���{�:� � �	��h�.<@J����~��>oZ,C5s�5W,��rm�E�37{����g~�I��d�V�*�ŮXFIe �İ�rB��˦I����Ɲ�í���WG+��j��7�1X���6���N�FZ�nwp���92�Ү�яh~D��0F
���D�T�j�ʛ(��!�8�K���1­��}&s��f�O�ɛi����������ә��VJj�[-�`���� ����:������X2�AlL`���N���G�3
����笐�9:#��ΰ?ſ7���TF�P�]2��A�[�F0
��@3Y�@�¦;�Zhg�h~O��H;� ���.d��!v�GS�a��%6�E�-(ag����Y�!�=���]˟�d3�������6L��z�@5���x�A��L�<\n��ϥ'�������x���*�G������4@��>X�������������r�<�o�W���,r���b{gk���Ҍ>��R1̉'z2\�J�S<�<m �����bz��&��숏��{�a��!*�uYLi=���a풅����g�܍J��3��u��SƂ�x�ȼiҿ�	�)j�����'�q;��a��0������̓dvt��!��JӏdB��-ȏOJ�-��`��t&p����]e�������@��bZ���e�F��I3�f4X[R�o��+HP�ט����1�5���-��fG���=LG:�!7A��$0e���Ɉ<MN`A�fK��|�����`�[,]et��R9fJ����b�×9A���R���2�)��u�j�/�i-6�2Q��m�b@������^��)D%t�z(�L�#��'�)�M�i�w���;8���h�𨷿�������8�p���د�nD'��N#��	߾��|�>pT�^�%ج~��O����1�w�����^�zK��NO���ZPO�k/d�&�)󚋑7� ���(�ſb4�<�T@��u�5K�AQ�E�h<t�7�����{�q��)'����3�{�)�Cig.�>��Xk���;��G�ř)o�^�D���ϟK�f����q�V�q�_a�E�6t/�	��y��ݏ:�e��������O?���߁Y}��Ac9��à�]�_M�"��1�.*�t�]FΏ�P�u:�����[� W����?����F�A��˷"�K�Xd�J���'��yA�9�Bg�6)̕���\���t����_����<��?W���8#-�1>l' V�g�5�(s��`��h���?`߆�D|E�n��� �>I�ݱ�ρ�U��jK2�j���W"���S�cц�����A�G�S��\~C �Ov��ꗱ7 �5s����Y�ɦ������C��E��X:D��S`E�~I�C�V$;�hM=��5�����:�i*������ۉn&�3-t���q���ӇOL����g�?�Q��uO<�{�D�5y�O�ȶ�aFwUҙ��/��0\���qd�U�		�AЦh����=��3������ܫ��E�5jvj�d�?�>����Gc�i�]x��FN�?N���Bg�uЬ�W���V�2�sT��oͿ�k ���|�w��We�`y��]�N�����Bg�ܖLZԍ	[i�W� ��ک����H������K:}�J��Z'���cq>Ki{ݨ��$!��S�R>�)�X�q��y����<�}����l��F�Q�e�Y��Y��Y��Y��Y��Y��Y��Y��Y��Y��Y��Y��Y��Y�D���{� @ 