#!/bin/bash
# Usage:  ./feed.sh ate [YYYY-MM-DD]       snake took the meal (default: today)
#         ./feed.sh refused [YYYY-MM-DD]   offered, refused
#         ./feed.sh interval 10            change feeding interval (days)
#         ./feed.sh plan YYYY-MM-DD        pin the next attempt to a date (cleared by ate/refused)
#         ./feed.sh shed [YYYY-MM-DD]      she shed her skin (default: today)
#         ./feed.sh                        show current state
set -eu; cd "$(dirname "$0")/.."   # the kit root
F=overlay/feeding.json; L=logs/feeding.log
[ -f $F ] || echo '{"lastAte":null,"lastOffered":null,"intervalDays":7}' > $F
today=$(date +%F); when=${2:-$today}
case "${1:-show}" in
  ate)      python3 -c "import json;d=json.load(open('$F'));d['lastAte']=d['lastOffered']='$when';d['nextPlanned']=None;json.dump(d,open('$F','w'))"
            echo "$when ate" >> $L ;;
  refused)  python3 -c "import json;d=json.load(open('$F'));d['lastOffered']='$when';d['nextPlanned']=None;json.dump(d,open('$F','w'))"
            echo "$when refused" >> $L ;;
  shed)     python3 -c "import json;d=json.load(open('$F'));d['lastShed']='$when';json.dump(d,open('$F','w'))"
            echo "$when shed" >> $L ;;
  plan)     python3 -c "import json;d=json.load(open('$F'));d['nextPlanned']='$when';json.dump(d,open('$F','w'))" ;;
  interval) python3 -c "import json;d=json.load(open('$F'));d['intervalDays']=int('$2');json.dump(d,open('$F','w'))" ;;
  show)     ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
# overlay reads this as a script tag (works from file:// where fetch() does not)
echo "window.FEEDING=$(cat $F);" > overlay/feeding.js
python3 -c "
import json,datetime as dt;d=json.load(open('$F'));t=dt.date.today()
p=lambda s: dt.date.fromisoformat(s) if s else None
ate,off,n=p(d['lastAte']),p(d['lastOffered']),d['intervalDays']
print('last ate     :', ate, f'({(t-ate).days} days ago)' if ate else '(not set - run: ./feed.sh ate YYYY-MM-DD)')
print('last offered :', off or '-')
nxt=p(d.get('nextPlanned')) or ((off or ate)+dt.timedelta(n) if (off or ate) else None)
print('last shed    :', d.get('lastShed') or '-')
print('next feed    :', nxt, '(planned)' if d.get('nextPlanned') else '', f'(in {(nxt-t).days} days)' if nxt else f'(every {n} days once a date is set)')"
