#!/bin/bash

set -o errexit

clike_file=
if [ $# -eq 1 ]; then
  clike_file="$1"
else
  clike_file="sample.oc.json"
fi

bname=$(basename $clike_file .oc.json)
asm_file="${bname}.oa.yaml"
bin_file="${bname}.ob.yaml"

ruby orecc.rb $clike_file > $asm_file
ruby oreasm.rb $asm_file > $bin_file
ruby orevm.rb $bin_file
