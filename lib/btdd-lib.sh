#!/bin/sh

function log {
    echo "$@" >&2
}

function prefix {
    local prefix="$1"
    shift
    "$@" | stdbuf -oL sed 's/^/'"$prefix"'/'
}

# Is it gpt or dos?
function _gpt_or_dos {
    local dev="$1"
    # [ -b "$dev" ] || log "not a block device" && return 1
    sfdisk -d "$dev" | sed -n 's/^label: //p'
}

# https://askubuntu.com/questions/57908/how-can-i-quickly-copy-a-gpt-partition-scheme-from-one-hard-drive-to-another
# gave me hints
#
function _dump_part_table {
    local dev="$1"
    local type=$(_gpt_or_dos "$dev")
    case "$type" in
        "dos")
            sfdisk -d "$dev"
            ;;
        "gpt")
            sgdisk --backup=/dev/stdout "$dev"
            ;;
        *)
            log "something's up in _gpt_or_dos on $dev"
            return 1;
            ;;
    esac
}

function _shrink_ext4 {
    local part="$1"
    e2fsck -y -f "$part";
    resize2fs -M "$part";
    e2fsck -y -f "$part";
    return 0
}

function _get_ext4_size {
    local part="$1"
    local count="$(dumpe2fs -h "$part" 2>/dev/null | sed -n 's/^Block count: *//p')"
    local bs="$(dumpe2fs -h "$part" 2>/dev/null | sed -n 's/^Block size: *//p')"
    echo "$((count*bs))"
}

function _shrink_part {
    ALIGN_SZ=4096 # force alignment to 4096-byte boundaries
    SEC_SZ=512
    local dev="$1"
    local part="$2"
    local type="$(_gpt_or_dos "$dev")"

    local partno="$(sfdisk -q -l -o Device "$dev" | nl -v0 -ba | grep -w "$part" | awk '{print $1}')"
    local newsize="$(_get_ext4_size "$part")"
    local newsize_k="$((1+newsize/1024))K"
    case "$type" in
        gpt)
            sgdisk -e "$dev";
            # I'm using sectors explicitly here, and hoping they're 512B
            local start="$(sfdisk -q -l -o Device,Start "$dev" | grep -we "$part" | awk '{print $2}')"
            local end="$(((1+(start*SEC_SZ+newsize)/ALIGN_SZ)*ALIGN_SZ/SEC_SZ))"
            local guid="$(sgdisk -i "$partno" "$dev" | sed -n 's/Partition unique GUID: //p')"
            local guidcode="$(sgdisk -i "$partno" "$dev" | sed -n 's/Partition GUID code: \([^ ]*\) .*/\1/p')"

            sgdisk -d "$partno" \
                   -n "$partno:$start:$end" \
                   -u "$partno:$guid" \
                   -t "$partno:$guidcode" \
                   "$dev"

            #partx -u "$partno" "$dev"
            #log "not implemented" ; exit 2
        ;;
        dos)
            echo ", $newsize_k" | sfdisk -N "$partno" "$dev"
            #partx -u "$partno" "$dev"
        ;;
    esac
}

function _make_blockdev_safe {
    local dev="$1"
    sync;
    umount "$dev"*;
}

function _list_ext4_parts {
    local dev="$1"
    lsblk -p -o name,fstype --list -f "$dev" |
        awk '$2 == "ext4" {print $1}'
}

function shrink_disk {
    local dev="$1"

    prefix "shrink> " echo "Syncing disks ..."
    _make_blockdev_safe "$dev"
    _list_ext4_parts "$dev" | while read part ; do

        prefix "shrink> " echo "Shrinking filesystem at $part ..."
        _shrink_ext4 "$part"

        prefix "shrink> " echo "Shrinking partition at $part ..."
        _shrink_part "$dev" "$part"

        cat > /dev/null # Skip all after the first partition
    done
}

function _create_blocks_for_file {
    local file="$1"
    local file_size="$2"
    local bs="$3"

    local full_blocks=$((file_size/bs-1))
    for block in $(seq 0 1 $full_blocks) ; do
        prefix "CREATING ...> " echo "$block" >&2
        local of="$(printf '.%0.8d' $block)"
        dd if="$file" bs="$bs" skip="$block" count=1 |
            sha1sum | awk '{print $1}' > "$of"
    done

    # ... and the last one ...
    local remainder="$((file_size % bs))"
    if [ "$remainder" -gt "0" ] ; then
        block="$((block+1))"
        prefix "CREATING ...> " echo "$block" >&2
        local of="$(printf '.%0.8d' $block)"
        dd if="$file" bs="$remainder" skip="$((block*bs))" iflag=skip_bytes count=1 |
            sha1sum | awk '{print $1}' > "$of"
    fi

    # Now we have a list of parts. We can xxd -r -p all parts together into one value for the pieces key.
    find . -type f -name '.0*' | sort |
        xargs cat | # should be in order ...
        xxd -r -p
}

function _parttable_end_address {
    local dev="$1"
    local lastsector="$(
      sfdisk -q -l -o Device,End "$dev" |
          tail -n+2 |
          awk '{print $2}' |
          sort -nr | head -1;)"
    echo "$((lastsector*512))"
}

function create_torrent {
    # need to use the above to bencode
    local dev="$1"
    local outfile="$2"

    local tmp="$(mktemp -d)"
    local piece_length=$((2**22))
    local file_size="$(_parttable_end_address "$dev")"

    local olddir="$PWD"
    cd "$tmp"

    _create_blocks_for_file "$dev" "$file_size" "$piece_length" > "pieces"

    # TODO
    # Replace this with bencode.lua
    testing_prefix="d8:announce28:udp://10.0.7.1:6969/announce10:created by7:btdd v013:creation datei`date +%s`e4:infod6:lengthi${file_size}e4:name26:2020-09-05_auron_paine.img12:piece lengthi${piece_length}e6:pieces$(wc -c "pieces" | awk '{print $1}'):"

    echo -n "$testing_prefix" > "$outfile"
    cat "pieces" >> "$outfile"
    echo -n "ee" >> "$outfile"
    cd "$olddir"
    rm -r "$tmp"
    echo "$tmp"
}
