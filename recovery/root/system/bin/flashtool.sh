#!/sbin/sh
#GQJZJY
PKG="$1"

if [ -e /proc/$$/fd/4 ]; then
    OUTFD=4
else
    OUTFD=1
fi

ui()   { printf 'ui_print %s\nui_print\n' "$1" >&"$OUTFD"; }
prog() { printf 'progress %s %s\n' "$1" "$2" >&"$OUTFD"; }

SUPER=/dev/block/by-name/super
TMP=/tmp/payload
THREADS=14
RESERVED=4194304

now()  { date +%s; }
secs() { echo $(( $2 - $1 )); }
fail() { ui "     [failed] $1"; ui ">>>>> Aborting installation <<<<<"; exit 1; }

hrsize() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1073741824) printf "%.1f GB", b/1073741824
        else if (b >= 1048576) printf "%.1f MB", b/1048576
        else if (b >= 1024) printf "%.1f KB", b/1024
        else printf "%d B", b
    }'
}

tmpfree_val() {
    F=$(df -k $TMP 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$F" ]; then
        if [ "$F" -ge 1048576 ]; then
            echo "$(expr $F / 1048576) GB"
        else
            echo "$(expr $F / 1024) MB"
        fi
    else
        echo "unknown"
    fi
}

[ -z "$PKG" ] && { echo "usage: $0 <ota.zip> [outfd]"; exit 1; }
[ ! -f "$PKG" ] && fail "package not found $PKG"
[ ! -b "$SUPER" ] && fail "super partition not found"
T0=$(now)

# ===== Tools =====
ui ">>>>> Checking Tools <<<<<"
for t in payload_extract lpmake mlpdump lpflash bootctl sha256sum blockdev; do
    P=$(command -v $t 2>/dev/null)
    [ -z "$P" ] && [ -x /system/bin/$t ] && P=/system/bin/$t
    [ -z "$P" ] && fail "$t not found"
    ui "     [ok] $(printf '%-18s found' "$t")"
done

# ===== Slot =====
ui ">>>>> Detecting Slot <<<<<"
CUR=$(bootctl get-current-slot 2>/dev/null)
case "$CUR" in
    0) SLOT=_b; OTHER=_a; ui "     current slot  :  [_a]"; ui "     target  slot  :  [_b]" ;;
    1) SLOT=_a; OTHER=_b; ui "     current slot  :  [_b]"; ui "     target  slot  :  [_a]" ;;
    *) SLOT=_a; OTHER=_b; ui "     current slot  :  [unknown]"; ui "     target  slot  :  [_a]  default" ;;
esac
prog 0.01 5

rm -rf $TMP
mkdir -p $TMP || fail "cannot create $TMP"
ui "     [tmp] free $(tmpfree_val)"

# ===== Parse OTA =====
ui ">>>>> Parsing OTA Package <<<<<"
PINFO=$TMP/pinfo.txt
payload_extract -i "$PKG" -p > "$PINFO" 2>&1 || fail "payload_extract -p"
[ -s "$PINFO" ] || fail "payload info empty"

GROUP=$(awk '/^DynamicPartition:/{f=1;next} f&&/name:/{print $2;exit}' "$PINFO")
DYN=$(awk '/^DynamicPartition:/{f=1;next} f&&/items:/{gsub(/.*\[|\].*/,"");gsub(/[",]/," ");print;exit}' "$PINFO")
[ -z "$GROUP" ] && fail "dynamic group not found"
[ -z "$DYN" ] && fail "dynamic partition list empty"
ui "     [group] $GROUP"

awk '$1=="name:" && NF>=6 {print $2, $4, $6}' "$PINFO" > $TMP/parts.txt

while read p sz h; do
    for d in $DYN; do
        [ "$p" = "$d" ] || continue
        eval "SZ_$p=$sz"; eval "H_$p=$h"
    done
done < $TMP/parts.txt

: > $TMP/static.txt
while read p sz h; do
    isd=0
    for d in $DYN; do [ "$p" = "$d" ] && { isd=1; break; }; done
    [ "$isd" = "0" ] && echo "$p $sz $h" >> $TMP/static.txt
done < $TMP/parts.txt
STATIC=$(awk '{print $1}' $TMP/static.txt)

IS_OPLUS=0
for p in $DYN; do [ "$p" = "my_stock" ] && IS_OPLUS=1; done
if [ "$IS_OPLUS" = "1" ]; then
    for p in my_company my_preload; do
        if [ -s /system/bin/$p.img ]; then
            sz=$(wc -c < /system/bin/$p.img)
            h=$(sha256sum /system/bin/$p.img | awk '{print $1}')
            eval "SZ_$p=$sz"; eval "H_$p=$h"
            DYN="$DYN $p"
            echo "$p $sz $h" >> $TMP/parts.txt
            ui "     [loaded] $p from /system/bin"
        else
            ui "     [missing] $p skipped"
        fi
    done
fi

DYN_COUNT=$(echo $DYN | wc -w)
STATIC_COUNT=$(echo $STATIC | wc -w)
ui "     [dynamic] $DYN_COUNT partitions"
ui "     [static]  $STATIC_COUNT partitions"
prog 0.05 5

# ===== Build metadata =====
ui ">>>>> Building Super Metadata <<<<<"
SUPERSIZE=$(blockdev --getsize64 $SUPER 2>/dev/null)
[ -z "$SUPERSIZE" ] && fail "cannot read super size"
GSIZE=$(expr $SUPERSIZE - $RESERVED)

SG="${GROUP}${SLOT}"
OG="${GROUP}${OTHER}"

LP="--metadata-size 65536 --super-name super --virtual-ab --block-size 4096"
LP="$LP --device-size $SUPERSIZE --metadata-slots 3"
LP="$LP --group ${SG}:$GSIZE --group ${OG}:$GSIZE"
for p in $DYN; do
    eval sz=\$SZ_$p
    LP="$LP --partition ${p}${SLOT}:readonly:$sz:${SG}"
    LP="$LP --partition ${p}${OTHER}:readonly:0:${OG}"
done

lpmake $LP --output $TMP/meta.img > $TMP/lpmake.log 2>&1
RC=$?
[ $RC -ne 0 ] && { while IFS= read -r l; do ui "     [lpmake] $l"; done < $TMP/lpmake.log; fail "lpmake"; }
ui "     [ok] meta.img written  $(wc -c < $TMP/meta.img) bytes"

mlpdump $TMP/meta.img > $TMP/lp.txt 2>&1
[ -s $TMP/lp.txt ] || fail "cannot read meta.img"
awk '/^  Name: /{n=$2} /linear super/{print n, $NF}' $TMP/lp.txt > $TMP/off.txt
[ -s $TMP/off.txt ] || fail "no offsets found"

# ===== Dynamic =====
ui ">>>>> Flashing Dynamic Partitions <<<<<"
DI=0
for p in $DYN; do
    DI=$((DI+1))
    tn="${p}${SLOT}"
    off=$(awk -v t="$tn" '$1==t{print $2}' $TMP/off.txt)
    [ -z "$off" ] && fail "$tn has no offset"

    ui "     [$DI/$DYN_COUNT]    $tn"

    case "$p" in
        my_company)
            src=/system/bin/my_company.img
            [ ! -s "$src" ] && fail "$p missing in /system/bin"
            ;;
        my_preload)
            src=/system/bin/my_preload.img
            [ ! -s "$src" ] && fail "$p missing in /system/bin"
            ;;
        *)
            src=$TMP/$p.img
            rm -f "$src"
            payload_extract -i "$PKG" -o "$TMP" -X "$p" -T"$THREADS" > /dev/null 2>&1
            [ $? -ne 0 ] && fail "$p extract failed"
            [ ! -f "$src" ] && [ -f "$TMP/payload/$p.img" ] && mv "$TMP/payload/$p.img" "$src"
            [ ! -s "$src" ] && fail "$p image not found"
            ;;
    esac

    fsz=$(wc -c < "$src")
    ui "     [extracted] $p    $(hrsize $fsz)"
    ui "     [flashing]  $tn    offset $off"
    ui "     [tmp] free $(tmpfree_val)"

    seek=$(expr $off \* 512)
    dd if="$src" of="$SUPER" bs=4M oflag=seek_bytes seek=$seek conv=notrunc > /dev/null 2>&1
    RC=$?
    sync
    [ $RC -ne 0 ] && fail "$p write failed"
    ui "     [write]     $tn    [ok]"

    case "$p" in
        my_company|my_preload) ;;
        *) rm -f "$src" ;;
    esac
    prog 0.$(printf "%02d" $((10 + DI*55/DYN_COUNT))) 1
done

# ===== Static =====
ui ">>>>> Flashing Static Partitions <<<<<"
ui "     [extracting] all static images"
static_csv=$(echo $STATIC | tr ' ' ',')
payload_extract -i "$PKG" -o "$TMP" -X "$static_csv" -T"$THREADS" > /dev/null 2>&1
ui "     [extracted]  all static images"
ui "     [tmp] free $(tmpfree_val)"

SI=0
while read p sz h; do
    SI=$((SI+1))
    dev=/dev/block/by-name/${p}${SLOT}
    [ ! -e "$dev" ] && dev=/dev/block/by-name/$p
    if [ ! -e "$dev" ]; then
        ui "     [$SI/$STATIC_COUNT]    $p    [no device]"
        continue
    fi

    src=$TMP/$p.img
    [ ! -f "$src" ] && [ -f "$TMP/payload/$p.img" ] && mv "$TMP/payload/$p.img" "$src"
    [ ! -s "$src" ] && fail "$p image not found"

    fsz=$(wc -c < "$src")
    ui "     [$SI/$STATIC_COUNT]    $p    $(hrsize $fsz)"

    if [ -n "$h" ] && [ "$h" != "-" ]; then
        ah=$(sha256sum "$src" | awk '{print $1}')
        [ "$ah" != "$h" ] && fail "$p source sha256 mismatch"
    fi

    dd if="$src" of="$dev" bs=4M conv=fsync > /dev/null 2>&1
    RC=$?
    sync
    [ $RC -ne 0 ] && fail "$p write failed"

    rb=$TMP/rb
    rm -f $rb
    cnt=$(expr $fsz / 4194304 + 1)
    dd if="$dev" of=$rb bs=4M count=$cnt > /dev/null 2>&1
    truncate -s $fsz $rb 2>/dev/null
    rh=$(sha256sum $rb | awk '{print $1}')
    rm -f $rb
    if [ -n "$h" ] && [ "$h" != "-" ]; then
        [ "$rh" != "$h" ] && fail "$p readback sha256 mismatch"
        ui "     [write]     $p    [ok]    verified"
    else
        ui "     [write]     $p    [ok]"
    fi

    rm -f "$src"
    prog 0.$(printf "%02d" $((65 + SI*28/STATIC_COUNT))) 1
done < $TMP/static.txt

# ===== Commit =====
ui ">>>>> Committing Super Metadata <<<<<"
lpflash "$SUPER" $TMP/meta.img
RC=$?
sync
[ $RC -ne 0 ] && fail "lpflash failed"
ui "     [lpflash]   applied"

mlpdump $SUPER > $TMP/final.txt 2>&1
for p in $DYN; do
    grep -q "Name: ${p}${SLOT}" $TMP/final.txt || fail "metadata missing ${p}${SLOT}"
done
ui "     [verify]    metadata    [ok]"
prog 0.95 1

# ===== Set active =====
ui ">>>>> Setting Active Slot <<<<<"
case "$SLOT" in
    _a) bootctl set-active-boot-slot 0 ;;
    _b) bootctl set-active-boot-slot 1 ;;
esac
[ $? -ne 0 ] && fail "bootctl failed"
ui "     [slot]      active set to $SLOT"
prog 0.97 1

# ===== SUCCESS =====
rm -rf $TMP
TT=$(secs $T0 $(now))
ui ">>>>> SUCCESSFUL <<<<<"
ui "     slot $SLOT    time ${TT}s"
prog 1.0 1
exit 0