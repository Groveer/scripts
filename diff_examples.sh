find /etc -type f -exec ls -la {} \; | awk '{print $5, $9}' | sort -k2 > /tmp/etc_orig_detailed.txt

find /mnt/chroot/etc -type f -exec ls -la {} \; | awk '{print $5, $9}' | sed 's|/mnt/chroot||' | sort -k2 > /tmp/etc_new_detailed.txt

# 比较
diff /tmp/etc_orig_detailed.txt /tmp/etc_new_detailed.txt

