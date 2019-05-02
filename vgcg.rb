# coding: utf-8
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
      fn_names.concat(pass1(stmt))
    }
  when "func"
    fn_names << rest[0]
  else
    raise "not yet impl"
  end

  fn_names
end

def def_func(rest, fn_names)
  fn_name = rest[0]
  fn_args = rest[1]
  body = rest[2]

  codes = []

  codes << "label #{fn_name}"

  codes << "push bp" # 呼び出し元の bp をスタックに push
  codes << "cp sp bp" # bp が呼び出し先になるように sp からコピー

  # 本体
  local_var_names_sub = []
  body.each{|stmt|
    body_codes = proc_stmt(stmt, fn_names, local_var_names_sub, fn_args)
    codes.concat(body_codes)
    if stmt[0] == "var"
      local_var_names_sub << stmt[1]
    end
  }

  codes << "cp bp sp" # 呼び出し元の bp を pop するために sp を移動
  codes << "pop bp" # 呼び出し元の bp に戻す
  codes << "ret"

  codes
end

def call_func(fn_name, rest, lvar_names, fn_args)
  codes = []

  # 逆順に積む
  rest.reverse.each{|arg|
    case arg
    when Integer
      codes << "push #{arg}"
    when String
      case
      when lvar_names.include?(arg)
        pos = lvar_names.index(arg) + 1
        codes << "push [bp-#{pos}]"
      when fn_args.include?(arg)
        pos = fn_args.index(arg) + 2
        codes << "push [bp+#{pos}]"
      else
        raise not_yet_impl(arg)
      end
    else
      raise not_yet_impl(arg)
    end
  }
  codes << "call #{fn_name}"

  # 引数の分を戻す
  codes << "add sp #{rest.size}"

  codes
end

def proc_case(whens, fn_names, lvar_names, fn_args)
  codes = []
  $label_id += 1
  label_id = $label_id

  when_idx = -1
  when_bodies = []
  whens.each{|_when|
    when_idx += 1
    cond, *rest = _when

    cond_head, *cond_rest = cond
    case cond_head
    when "eq", "gt", "lt"
      codes << "label test_#{label_id}_#{when_idx}"
      codes.concat render_exp(cond, lvar_names, fn_args) #=> 結果は reg_a
      codes << "set_reg_b 1"
      codes << "compare_v2"

      # reg_a == 1 (結果が true) の場合
      codes << "jump_eq when_#{label_id}_#{when_idx}"

      # reg_a != 1 (結果が false) の場合
      if when_idx + 1 < whens.size
        # 次の条件を試す
        codes << "jump test_#{label_id}_#{when_idx + 1}"
      else
        # 最後へ
        codes << "jump end_case_#{label_id}"
      end

      then_stmts = ["label when_#{label_id}_#{when_idx}"]
      rest.each{|stmt|
        then_stmts.concat proc_stmt(stmt, fn_names, lvar_names, fn_args)
      }
      then_stmts << "jump end_case_#{label_id}"
      when_bodies << then_stmts
    else
      raise "not yet impl (#{cond_head})"
    end
  }

  when_bodies.each{|then_stmts|
    then_stmts.each{|stmt|
      codes << stmt
    }
  }

  codes << "label end_case_#{label_id}"

  codes
end

def proc_while(rest, fn_names, lvar_names, fn_args)
  cond_exp, body = rest
  codes = []
  $label_id += 1
  label_id = $label_id

  codes << "label while_#{label_id}"
  codes.concat render_exp(cond_exp, lvar_names, fn_args)
  codes << "set_reg_b 1"
  codes << "compare_v2"
  codes << "jump_eq true_#{label_id}"
  # false の場合ループを抜ける
  codes << "jump end_while_#{label_id}"

  codes << "label true_#{label_id}"
  # true の場合 body を実行

  body.each{|stmt|
    codes.concat proc_stmt(stmt, fn_names, lvar_names, fn_args)
  }

  codes << "jump while_#{label_id}"

  codes << "label end_while_#{label_id}"

  codes
end

# 2引数の式を展開
def proc_exp_two(left, right, lvar_names, fn_args)
  codes = []

  # 終端でなければ、先に深い方を処理する
  if left.is_a? Array
    codes.concat render_exp(left, lvar_names)
    codes << "cp reg_a reg_d" #=> 評価結果を退避 a => d
  end

  if right.is_a? Array
    codes.concat render_exp(right, lvar_names)
    # 評価結果は a に入ってる
  end

  # 終端の処理
  case left
  when Array
    ; # skip
  when Integer
    codes << "set_reg_d #{left}"
  when String
    case
    when /^\d+$/ =~ left
      codes << "set_reg_d #{left}"
    when lvar_names.include?(left)
      pos = lvar_names.index(left) + 1
      codes << "set_reg_d [bp-#{pos}]"
    when fn_args.include?(left)
      pos = fn_args.index(left) + 2
      codes << "set_reg_d [bp+#{pos}]"
    else
      raise "not yet impl (#{left})"
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
    #   codes << "set_reg_d #{right}"
    when lvar_names.include?(right)
      pos = lvar_names.index(right) + 1
      codes << "set_reg_a [bp-#{pos}]"
    when fn_args.include?(right)
      pos = fn_args.index(right) + 2
      codes << "set_reg_a [bp+#{pos}]"
    else
      raise "not yet impl (#{right})"
    end
  else
    codes << "set_reg_a #{right}"
  end

  codes
end

# 結果は reg_a に入れる
def builtin_add(rest, lvar_names, fn_args)
  left, right = rest
  codes = []

  codes.concat proc_exp_two(left, right, lvar_names, fn_args)

  codes << "cp reg_d reg_b"
  codes << "add_ab_v2" #=> reg_a に入る

  codes
end

# 結果は reg_a に入れる
def builtin_sub(rest, lvar_names, fn_args)
  left, right = rest
  codes = []

  codes.concat proc_exp_two(left, right, lvar_names, fn_args)

  # きれいではないが a - b となるように入れ替え
  # 加算のときは順番関係ないので問題に気づけてなかった…
  codes << "cp reg_a reg_c"
  codes << "cp reg_d reg_a"
  codes << "cp reg_c reg_b"

  codes << "sub_ab" #=> reg_a に入る

  codes
end

# 結果は reg_a に入れる
def builtin_mult(rest, lvar_names)
  left, right = rest
  codes = []

  codes.concat proc_exp_two(left, right, lvar_names)

  codes << "cp reg_d reg_b"
  codes << "mult_ab" #=> reg_a に入る

  codes
end

# 結果は reg_a に入れる
def builtin_mult(rest, lvar_names, fn_args)
  left, right = rest
  codes = []

  codes.concat proc_exp_two(left, right, lvar_names, fn_args)

  codes << "cp reg_d reg_b"
  codes << "mult_ab"

  codes
end

# 結果は reg_a に入れる
def builtin_eq(rest, lvar_names, fn_args)
  left, right = rest
  codes = []
  $label_id +=1
  label_id = $label_id

  codes.concat proc_exp_two(left, right, lvar_names, fn_args)

  codes << "cp reg_d reg_b"
  codes << "compare_v2"
  codes << "jump_eq then_#{label_id}"
  # else
  codes << "set_reg_a 0"
  codes << "jump end_eq_#{label_id}"

  # then
  codes << "label then_#{label_id}"
  codes << "set_reg_a 1"

  codes << "label end_eq_#{label_id}"

  codes
end

# 結果は reg_a に入れる
# left > right の場合 true
def builtin_gt(rest, lvar_names, fn_args)
  left, right = rest
  codes = []
  $label_id +=1
  label_id = $label_id

  codes.concat proc_exp_two(left, right, lvar_names, fn_args)

  codes << "cp reg_d reg_b"
  codes << "compare_v2"
  codes << "jump_above then_#{label_id}"
  # else
  codes << "set_reg_a 0"
  codes << "jump end_gt_#{label_id}"

  # then
  codes << "label then_#{label_id}"
  codes << "set_reg_a 1"

  codes << "label end_gt_#{label_id}"

  codes
end

# 結果は reg_a に入れる
# left < right の場合 true
def builtin_lt(rest, lvar_names, fn_args)
  left, right = rest
  codes = []
  $label_id +=1
  label_id = $label_id

  codes.concat proc_exp_two(left, right, lvar_names, fn_args)

  codes << "cp reg_d reg_b"
  codes << "compare_v2"
  codes << "jump_below then_#{label_id}"
  # else
  codes << "set_reg_a 0"
  codes << "jump end_lt_#{label_id}"

  # then
  codes << "label then_#{label_id}"
  codes << "set_reg_a 1"

  codes << "label end_lt_#{label_id}"

  codes
end

def builtin_neq(rest, lvar_names, fn_args)
  left, right = rest
  codes = []
  $label_id +=1
  label_id = $label_id

  codes.concat proc_exp_two(left, right, lvar_names, fn_args)

  codes << "cp reg_d reg_b"
  codes << "compare_v2"
  codes << "jump_eq then_#{label_id}"
  # else
  codes << "set_reg_a 1"
  codes << "jump end_neq_#{label_id}"

  # then
  codes << "label then_#{label_id}"
  codes << "set_reg_a 0"

  codes << "label end_neq_#{label_id}"

  codes
end

def render_exp(exp, lvar_names, fn_args)
  head, *rest = exp
  codes = []

  case head
  when "+"
    codes.concat builtin_add(rest, lvar_names, fn_args)
  when "-"
    codes.concat builtin_sub(rest, lvar_names, fn_args)
  when "*"
    codes.concat builtin_mult(rest, lvar_names, fn_args)
  when "eq"
    codes.concat builtin_eq(rest, lvar_names, fn_args)
  when "gt"
    codes.concat builtin_gt(rest, lvar_names, fn_args)
  when "lt"
    codes.concat builtin_lt(rest, lvar_names, fn_args)
  when "neq"
    codes.concat builtin_neq(rest, lvar_names, fn_args)
  else
    raise not_yet_impl(head)
  end

  codes
end

def _debug(msg)
  "_debug " + msg.gsub(" ", "_")
end

def proc_stmt(tree, fn_names, lvar_names, fn_args)
  codes = []

  head, *rest = tree
  case head
  when "stmts"
    rest.each{|stmt|
      cds = proc_stmt(stmt, fn_names, lvar_names, fn_args)
      codes.concat(cds)
    }
  when "func"
    cds = def_func(rest, fn_names)
    codes.concat(cds)
  when "noop"
    codes << "noop"
  when "var"
    # ローカル変数の宣言（スタック確保）
    codes << "sub sp 1"
  when "set" # dest src
    # ローカル変数への代入

    src_val =
      if rest[1].is_a? Integer
        rest[1]
      elsif rest[1].is_a? Array
        exp = rest[1]
        codes.concat render_exp(exp, lvar_names, fn_args)
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
      elsif /^arr\[(\d+)\]$/ =~ rest[1]
        rest[1]
      elsif /^arr\[([a-z_][a-z0-9_]*)\]$/ =~ rest[1]
        var_name = $1
        case
        when lvar_names.include?(var_name)
          var_pos = lvar_names.index(var_name) + 1
          codes << "get_vram [bp-#{var_pos}] reg_a"
        else
          raise not_yet_impl(var_name)
        end
        "reg_a"
      else
        raise not_yet_impl(tree)
      end

    var_name = rest[0]
    case var_name
    when /^arr\[(.+)\]$/
      idx = $1
      case idx
      when /^\d+$/
        codes << "cp #{src_val} #{var_name}"
      when /^([a-z_][a-z0-9_]*)$/
        var_name = $1
        case
        when lvar_names.include?(var_name)
          var_pos = lvar_names.index(var_name) + 1
          codes << "set_vram [bp-#{var_pos}] #{src_val}"
        else
          raise not_yet_impl(var_name)
        end
      else
        raise not_yet_impl(var_name)
      end
    else
      var_pos = lvar_names.index(var_name) + 1
      codes << "cp #{src_val} [bp-#{var_pos}]"
    end
  when "+"
    codes.concat builtin_add(rest, lvar_names)
  when "*"
    codes.concat builtin_mult(rest, lvar_names)
  when "eq"
    codes.concat render_exp(tree, lvar_names, fn_args)
  when "gt", "lt"
    codes.concat render_exp(tree, lvar_names, fn_args)
  when "neq"
    codes.concat render_exp(tree, lvar_names, fn_args)
  when "return"
    retval = rest[0]
    case
    when /^arr\[(.+)\]$/ =~ retval
      idx = $1
      case idx
      when /^(\d+)$/
        raise not_yet_impl(retval)
      when /^([a-z_][a-z0-9_]+)$/
        var_name = $1
        case
        when lvar_names.include?(var_name)
          var_pos = lvar_names.index(var_name) + 1
          codes << "get_vram [bp-#{var_pos}] reg_a"
        else
          raise not_yet_impl(var_name)
        end
      else
        raise not_yet_impl(retval)
      end
    when lvar_names.include?(retval)
      var_pos = lvar_names.index(retval) + 1
      codes << "cp [bp-#{var_pos}] reg_a"
    else
      codes << "cp #{retval} reg_a"
    end
  when "call_set"
    lvar_name = rest[0]
    unless rest[1].is_a? Array
      raise "syntax error: rest[1] must be an array"
    end
    fn_name, *tmp_fn_args = rest[1]
    codes << _debug("-->> call_set " + fn_name)
    cds = call_func(fn_name, tmp_fn_args, lvar_names, fn_args)
    codes.concat(cds)

    # 返り値をセット
    lvar_pos = lvar_names.index(lvar_name) + 1
    codes << "cp reg_a [bp-#{lvar_pos}]"
    codes << _debug("<<-- call_set " + fn_name)
  when "call"
    fn_name, *tmp_fn_args = rest
    codes << _debug("-->> call " + fn_name)
    cds = call_func(fn_name, tmp_fn_args, lvar_names, fn_args)
    codes.concat(cds)
    codes << _debug("<<-- call " + fn_name)
  when "case"
    codes << _debug("-->> case")
    codes.concat proc_case(rest, fn_names, lvar_names, fn_args)
    codes << _debug("<<-- case")
  when "while"
    codes << _debug("-->> while")
    codes.concat proc_while(rest, fn_names, lvar_names, fn_args)
    codes << _debug("<<-- while")
  when "_debug"
    codes << _debug(rest[0])
  else
    raise "not yet impl (#{tree.inspect})"
  end

  codes
end

def main(args)
  src = File.read(args[0])
  src2 = src.split("\n").select{|line|
    %r{^ *//} !~ line
  }.join("\n")
  tree = JSON.parse(src2)

  fn_names = pass1(tree)
  lvar_names = []

  codes = []
  codes.concat([
                 "call main",
                 "exit",
               ])
  cds = proc_stmt(tree, fn_names, lvar_names, [])
  codes.concat(cds)

  puts YAML.dump(codes)
end

main(ARGV)
