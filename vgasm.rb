# coding: utf-8
require "pp"
require "yaml"

src = File.read(ARGV[0])

list = YAML.load(src)

# ラベル名とアドレスのマッピングを作成
label_addr_map = {}

i = 0
list.each{|line|
  head, *rest = line.split(" ")
  case head
  when "label"
    name = rest[0]
    label_addr_map[name] = i
    i += 2
  else
    i += 1 # head の分
    i += rest.size
  end
}

list2 = []
list.each{|line|
  head, *rest = line.split(" ")
  case head
  when "label"
    list2 << head
    list2 << rest[0]
  when "jump"
    list2 << head
    list2 << label_addr_map[rest[0]] + 2
  when "call"
    list2 << head
    list2 << label_addr_map[rest[0]] + 2
  when "jump_eq", "jump_above", "jump_below"
    list2 << head
    list2 << label_addr_map[rest[0]] + 2
  else
    list2 << head
    rest.each{|opr|
      list2 <<
        case opr
        when /^\d+$/, /^\-\d+$/
          opr.to_i
        else
          opr
        end
    }
  end
}

$stderr.puts "size (#{ list2.size })"

puts YAML.dump(list2)
