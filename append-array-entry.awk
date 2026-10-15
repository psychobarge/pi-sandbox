# Appends one entry to a bash array in pi.conf, just before the array's
# closing ")". A list may be written on one line (`ALLOWED=("/a" "/b")`), where
# no line starts with ")", so the end of the array is found by paren depth,
# ignoring parens inside double quotes and comments.
#   awk -v array=ALLOWED -v entry='"/path"' -f append-array-entry.awk pi.conf
{
  if (!in_block && $0 ~ "^[[:space:]]*" array "=\\(") { in_block=1; depth=0 }
  if (!in_block) { print; next }
  if (index($0, entry) > 0) found=1

  line=$0; out=""; q=0
  for (i=1; i<=length(line); i++) {
    c=substr(line,i,1)
    if (c=="\\") { out=out c; if (i<length(line)) { i++; out=out substr(line,i,1) }; continue }
    if (c=="\"") { q=!q; out=out c; continue }
    if (!q && c=="#") { out=out substr(line,i); break }
    if (!q && c=="(") depth++
    if (!q && c==")") {
      depth--
      if (depth==0) {
        if (!found) out=out "  " entry "\n"
        out=out c
        in_block=0
        print out substr(line,i+1)
        next
      }
    }
    out=out c
  }
  print out
}
