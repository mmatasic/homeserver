date=$(date '+%Y%m%d' | cut -c 3-)

grep skip ~/beet.log | sed 's/skip //' > ~/skipped_import.log

mv ~/beet.log ~/beet.log."$date"

manual_import() {
until [ ! -s ~/skipped_import.log ]
do
  chek=$(head -n 1 ~/skipped_import.log)
  beet import "$chek" &&
  sed -i '1d' ~/skipped_import.log
done
}

manual_import
