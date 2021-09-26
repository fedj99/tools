len=$([ -z $1 ] && echo 8 || echo $1)

echo $RANDOM | md5sum | head -c $len
echo
