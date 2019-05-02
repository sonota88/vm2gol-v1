#!/bin/bash

set -o errexit

clike_file="$1"
bname=$(basename $clike_file .vgt.json)
asm_file="${bname}.vga.yaml"
bin_file="${bname}.vge.yaml"

ruby orecc.rb $clike_file > $asm_file
ruby oreasm.rb $asm_file > $bin_file
ruby orevm.rb $bin_file
