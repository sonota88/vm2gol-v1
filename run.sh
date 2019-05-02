#!/bin/bash

set -o errexit

tree_file="$1"
bname=$(basename $tree_file .vgt.json)
asm_file="${bname}.vga.yaml"
exe_file="${bname}.vge.yaml"

ruby vgcg.rb $tree_file > $asm_file
ruby vgasm.rb $asm_file > $exe_file
ruby vgvm.rb $exe_file
