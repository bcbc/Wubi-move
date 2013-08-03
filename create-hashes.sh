md5sum wubi-move.sh check-source.sh check-target.sh verify.sh > MD5SUMS
gpg --local-user openbcbc@gmail.com --output MD5SUMS.gpg --armor --detach-sign  MD5SUMS
sha256sum wubi-move.sh check-source.sh check-target.sh verify.sh > SHA256SUMS
gpg --local-user openbcbc@gmail.com --output SHA256SUMS.gpg --armor --detach-sign  SHA256SUMS
