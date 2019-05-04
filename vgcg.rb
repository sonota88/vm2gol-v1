# coding: utf-8

# alines: asm lines

require "json"
require "yaml"
require "pp"

require "./common"

$label_id = 0

def pass1(tree)
  fn_names = []

  head, *rest = tree
  case head
  when "stmts"
    rest.each{|stmt|
      fn_names += pass1(stmt)
    }
  when "func"
    fn_names << rest[0]
  else
    raise not_yet_impl(head)
  end

  fn_names
end

def render_func_def(rest, fn_names)
  fn_name = rest[0]
  fn_args = rest[1]
  body = rest[2]

  alines = []

  alines << "label #{fn_name}"

  alines << "push bp" # 呼び出し元の bp をスタックに push
  alines << "cp sp bp" # bp が呼び出し先になるように sp からコピー

  # 本体
  local_var_names_sub = []
  body.each do |stmt|
    alines += render_stmt(stmt, fn_names, local_var_names_sub, fn_args)
    if stmt[0] == "var"
      local_var_names_sub << stmt[1]
    end
  end

  alines << "cp bp sp" # 呼び出し元の bp を pop するために sp を移動
  alines << "pop bp" # 呼び出し元の bp に戻す
  alines << "ret"

  alines
end

def render_func_call(fn_name, rest, lvar_names, fn_args)
  alines = []

  # 逆順に積む
  rest.reverse.each do |arg|
    case arg
    when Integer
      alines << "push #{arg}"
    when String
      case
      when lvar_names.include?(arg)
        pos = lvar_names.index(arg) + 1
        alines << "push [bp-#{pos}]"
      when fn_args.include?(arg)
        pos = fn_args.index(arg) + 2
        alines << "push [bp+#{pos}]"
      else
        raise not_yet_impl(arg)
      end
    else
      raise not_yet_impl(arg)
    end
  end
  alines << "call #{fn_name}"

  # 引数の分を戻す
  alines << "add sp #{rest.size}"

  alines
end

def render_case(whens, fn_names, lvar_names, fn_args)
  alines = []
  $label_id += 1
  label_id = $label_id

  when_idx = -1
  when_bodies = []
  whens.each do |_when|
    when_idx += 1
    cond, *rest = _when

    cond_head, *cond_rest = cond
    case cond_head
    when "eq", "gt", "lt"
      alines << "label test_#{label_id}_#{when_idx}"
      alines += render_exp(cond, lvar_names, fn_args) #=> 結果は reg_a
      alines << "set_reg_b 1"
      alines << "compare_v2"

      # reg_a == 1 (結果が true) の場合
      alines << "jump_eq when_#{label_id}_#{when_idx}"

      # reg_a != 1 (結果が false) の場合
      if when_idx + 1 < whens.size
        # 次の条件を試す
        alines << "jump test_#{label_id}_#{when_idx + 1}"
      else
        # 最後へ
        alines << "jump end_case_#{label_id}"
      end

      then_stmts = ["label when_#{label_id}_#{when_idx}"]
      rest.each{|stmt|
        then_stmts += render_stmt(stmt, fn_names, lvar_names, fn_args)
      }
      then_stmts << "jump end_case_#{label_id}"
      when_bodies << then_stmts
    else
      raise not_yet_impl(cond_head)
    end
  end

  when_bodies.each{|then_stmts|
    then_stmts.each{|stmt|
      alines << stmt
    }
  }

  alines << "label end_case_#{label_id}"

  alines
end

def render_while(rest, fn_names, lvar_names, fn_args)
  cond_exp, body = rest
  alines = []
  $label_id += 1
  label_id = $label_id

  alines << "label while_#{label_id}"
  alines += render_exp(cond_exp, lvar_names, fn_args)
  alines << "set_reg_b 1"
  alines << "compare_v2"
  alines << "jump_eq true_#{label_id}"
  # false の場合ループを抜ける
  alines << "jump end_while_#{label_id}"

  alines << "label true_#{label_id}"
  # true の場合 body を実行

  body.each{|stmt|
    alines += render_stmt(stmt, fn_names, lvar_names, fn_args)
  }

  alines << "jump while_#{label_id}"

  alines << "label end_while_#{label_id}"

  alines
end

# 2引数の式を展開
def render_exp_two(left, right, lvar_names, fn_args)
  alines = []

  # 終端でなければ、先に深い方を処理する
  if left.is_a? Array
    alines += render_exp(left, lvar_names)
    alines << "cp reg_a reg_d" #=> 評価結果を退避 a => d
  end

  if right.is_a? Array
    alines += render_exp(right, lvar_names)
    # 評価結果は a に入ってる
  end

  # 終端の処理
  case left
  when Array
    ; # skip
  when Integer
    alines << "set_reg_d #{left}"
  when String
    case
    when /^\d+$/ =~ left
      alines << "set_reg_d #{left}"
    when lvar_names.include?(left)
      pos = lvar_names.index(left) + 1
      alines << "set_reg_d [bp-#{pos}]"
    when fn_args.include?(left)
      pos = fn_args.index(left) + 2
      alines << "set_reg_d [bp+#{pos}]"
    else
      raise not_yet_impl(left)
    end
  else
    raise not_yet_impl(left)
  end

  case right
  when Array
    ; # skip
  when String
    case
    # when /^\d+$/ =~ right
    #   alines << "set_reg_d #{right}"
    when lvar_names.include?(right)
      pos = lvar_names.index(right) + 1
      alines << "set_reg_a [bp-#{pos}]"
    when fn_args.include?(right)
      pos = fn_args.index(right) + 2
      alines << "set_reg_a [bp+#{pos}]"
    else
      raise not_yet_impl(right)
    end
  else
    alines << "set_reg_a #{right}"
  end

  alines
end

# 結果は reg_a に入れる
def render_builtin_add(rest, lvar_names, fn_args)
  left, right = rest
  alines = []

  alines += render_exp_two(left, right, lvar_names, fn_args)

  alines << "cp reg_d reg_b"
  alines << "add_ab_v2" #=> reg_a に入る

  alines
end

# 結果は reg_a に入れる
def render_builtin_sub(rest, lvar_names, fn_args)
  left, right = rest
  alines = []

  alines += render_exp_two(left, right, lvar_names, fn_args)

  # きれいではないが a - b となるように入れ替え
  # 加算のときは順番関係ないので問題に気づけてなかった…
  alines << "cp reg_a reg_c"
  alines << "cp reg_d reg_a"
  alines << "cp reg_c reg_b"

  alines << "sub_ab" #=> reg_a に入る

  alines
end

# 結果は reg_a に入れる
def render_builtin_mult(rest, lvar_names, fn_args)
  left, right = rest
  alines = []

  alines += render_exp_two(left, right, lvar_names, fn_args)

  alines << "cp reg_d reg_b"
  alines << "mult_ab"

  alines
end

# 結果は reg_a に入れる
def render_builtin_eq(rest, lvar_names, fn_args)
  left, right = rest
  alines = []
  $label_id +=1
  label_id = $label_id

  alines += render_exp_two(left, right, lvar_names, fn_args)

  alines << "cp reg_d reg_b"
  alines << "compare_v2"
  alines << "jump_eq then_#{label_id}"
  # else
  alines << "set_reg_a 0"
  alines << "jump end_eq_#{label_id}"

  # then
  alines << "label then_#{label_id}"
  alines << "set_reg_a 1"

  alines << "label end_eq_#{label_id}"

  alines
end

# 結果は reg_a に入れる
# left > right の場合 true
def render_builtin_gt(rest, lvar_names, fn_args)
  left, right = rest
  alines = []
  $label_id +=1
  label_id = $label_id

  alines += render_exp_two(left, right, lvar_names, fn_args)

  alines << "cp reg_d reg_b"
  alines << "compare_v2"
  alines << "jump_above then_#{label_id}"
  # else
  alines << "set_reg_a 0"
  alines << "jump end_gt_#{label_id}"

  # then
  alines << "label then_#{label_id}"
  alines << "set_reg_a 1"

  alines << "label end_gt_#{label_id}"

  alines
end

# 結果は reg_a に入れる
# left < right の場合 true
def render_builtin_lt(rest, lvar_names, fn_args)
  left, right = rest
  alines = []
  $label_id +=1
  label_id = $label_id

  alines += render_exp_two(left, right, lvar_names, fn_args)

  alines << "cp reg_d reg_b"
  alines << "compare_v2"
  alines << "jump_below then_#{label_id}"
  # else
  alines << "set_reg_a 0"
  alines << "jump end_lt_#{label_id}"

  # then
  alines << "label then_#{label_id}"
  alines << "set_reg_a 1"

  alines << "label end_lt_#{label_id}"

  alines
end

def render_builtin_neq(rest, lvar_names, fn_args)
  left, right = rest
  alines = []
  $label_id +=1
  label_id = $label_id

  alines += render_exp_two(left, right, lvar_names, fn_args)

  alines << "cp reg_d reg_b"
  alines << "compare_v2"
  alines << "jump_eq then_#{label_id}"
  # else
  alines << "set_reg_a 1"
  alines << "jump end_neq_#{label_id}"

  # then
  alines << "label then_#{label_id}"
  alines << "set_reg_a 0"

  alines << "label end_neq_#{label_id}"

  alines
end

def render_exp(exp, lvar_names, fn_args)
  head, *rest = exp
  alines = []

  case head
  when "+"
    alines += render_builtin_add(rest, lvar_names, fn_args)
  when "-"
    alines += render_builtin_sub(rest, lvar_names, fn_args)
  when "*"
    alines += render_builtin_mult(rest, lvar_names, fn_args)
  when "eq"
    alines += render_builtin_eq(rest, lvar_names, fn_args)
  when "gt"
    alines += render_builtin_gt(rest, lvar_names, fn_args)
  when "lt"
    alines += render_builtin_lt(rest, lvar_names, fn_args)
  when "neq"
    alines += render_builtin_neq(rest, lvar_names, fn_args)
  else
    raise not_yet_impl(head)
  end

  alines
end

# ローカル変数への代入
def render_set(rest, lvar_names, fn_args)
  alines = []

  src_val =
    if rest[1].is_a? Integer
      rest[1]
    elsif rest[1].is_a? Array
      exp = rest[1]
      alines += render_exp(exp, lvar_names, fn_args)
      "reg_a" # 結果を reg_a から回収する
    elsif fn_args.include?(rest[1])
      # pos = 0 ... 1個目の引数
      # [bp+(pos+2)] にしたい
      pos = fn_args.index(rest[1])
      "[bp+#{ pos + 2 }]"
    elsif lvar_names.include?(rest[1])
      pos = lvar_names.index(rest[1]) + 1
      "[bp-#{pos}]"
    elsif rest[1] == "reg_a"
      "reg_a"
    elsif /^vram\[(\d+)\]$/ =~ rest[1]
      rest[1]
    elsif /^vram\[([a-z_][a-z0-9_]*)\]$/ =~ rest[1]
      var_name = $1
      case
      when lvar_names.include?(var_name)
        var_pos = lvar_names.index(var_name) + 1
        alines << "get_vram [bp-#{var_pos}] reg_a"
      else
        raise not_yet_impl(var_name)
      end
      "reg_a"
    else
      raise not_yet_impl(tree)
    end

  var_name = rest[0]
  case var_name
  when /^vram\[(.+)\]$/
    idx = $1
    case idx
    when /^\d+$/
      alines << "cp #{src_val} #{var_name}"
    when /^([a-z_][a-z0-9_]*)$/
      var_name = $1
      case
      when lvar_names.include?(var_name)
        var_pos = lvar_names.index(var_name) + 1
        alines << "set_vram [bp-#{var_pos}] #{src_val}"
      else
        raise not_yet_impl(var_name)
      end
    else
      raise not_yet_impl(var_name)
    end
  else
    var_pos = lvar_names.index(var_name) + 1
    alines << "cp #{src_val} [bp-#{var_pos}]"
  end

  alines
end

def render_return(rest, lvar_names)
  alines = []

  retval = rest[0]
  case
  when /^vram\[(.+)\]$/ =~ retval
    idx = $1
    case idx
    when /^(\d+)$/
      raise not_yet_impl(retval)
    when /^([a-z_][a-z0-9_]+)$/
      var_name = $1
      case
      when lvar_names.include?(var_name)
        var_pos = lvar_names.index(var_name) + 1
        alines << "get_vram [bp-#{var_pos}] reg_a"
      else
        raise not_yet_impl(var_name)
      end
    else
      raise not_yet_impl(retval)
    end
  when lvar_names.include?(retval)
    var_pos = lvar_names.index(retval) + 1
    alines << "cp [bp-#{var_pos}] reg_a"
  else
    alines << "cp #{retval} reg_a"
  end

  alines
end

def _debug(msg)
  "_debug " + msg.gsub(" ", "_")
end

def render_stmt(tree, fn_names, lvar_names, fn_args)
  alines = []

  head, *rest = tree
  case head
  when "stmts"
    rest.each{|stmt|
      alines += render_stmt(stmt, fn_names, lvar_names, fn_args)
    }
  when "func"
    alines += render_func_def(rest, fn_names)
  when "noop"
    alines << "noop"
  when "var"
    # ローカル変数の宣言（スタック確保）
    alines << "sub sp 1"
  when "set" # dest src
    alines += render_set(rest, lvar_names, fn_args)
  when "+"
    alines += render_builtin_add(rest, lvar_names)
  when "*"
    alines += render_builtin_mult(rest, lvar_names)
  when "eq"
    alines += render_exp(tree, lvar_names, fn_args)
  when "gt", "lt"
    alines += render_exp(tree, lvar_names, fn_args)
  when "neq"
    alines += render_exp(tree, lvar_names, fn_args)
  when "return"
    alines += render_return(rest, lvar_names)
  when "call_set"
    lvar_name = rest[0]
    unless rest[1].is_a? Array
      raise "syntax error: rest[1] must be an array"
    end
    fn_name, *tmp_fn_args = rest[1]
    alines << _debug("-->> call_set " + fn_name)
    alines += render_func_call(fn_name, tmp_fn_args, lvar_names, fn_args)

    # 返り値をセット
    lvar_pos = lvar_names.index(lvar_name) + 1
    alines << "cp reg_a [bp-#{lvar_pos}]"
    alines << _debug("<<-- call_set " + fn_name)
  when "call"
    fn_name, *tmp_fn_args = rest
    alines << _debug("-->> call " + fn_name)
    alines += render_func_call(fn_name, tmp_fn_args, lvar_names, fn_args)
    alines << _debug("<<-- call " + fn_name)
  when "case"
    alines << _debug("-->> case")
    alines += render_case(rest, fn_names, lvar_names, fn_args)
    alines << _debug("<<-- case")
  when "while"
    alines << _debug("-->> while")
    alines += render_while(rest, fn_names, lvar_names, fn_args)
    alines << _debug("<<-- while")
  when "_debug"
    alines << _debug(rest[0])
  else
    raise not_yet_impl(tree)
  end

  alines
end

def main(args)
  src = File.read(args[0])
  tree = JSON.parse(src)

  fn_names = pass1(tree)
  lvar_names = []

  alines = []
  alines += [
                 "call main",
                 "exit",
               ]
  alines += render_stmt(tree, fn_names, lvar_names, [])

  puts YAML.dump(alines)
end

main(ARGV)
