# coding: utf-8
require "pp"
require "yaml"
require "./common"

module Escseq
  RESET = "\e[m"
  INVERT = "\e[7m"
  BLUE = "\e[0;34m"
  RED = "\e[0;31m"
end

class Memory

  attr_accessor :main, :stack, :vram

  MAIN_DUMP_WIDTH = 30

  def initialize(stack_size)
    # @mem = Array.new(8, 0)
    @main = []

    @stack = Array.new(stack_size, nil)

    @vram = Array.new(50, 0)
  end

  def dump_main(ip)
    lines = []

    i = 0
    while i < @main.size
      x = @main[i]
      num_args =
        case x
        when "cp", "add", "sub", "set_vram", "get_vram"
          2
        when "push", "pop", "call", "set_reg_a", "set_reg_b", "set_reg_d", "label", "jump_eq", "jump", "jump_above", "jump_below", "_debug"
          1
        else
          0
        end
      lines << {
        :i => i,
        :xs => @main[i..i+num_args]
      }
      i += 1 + num_args
    end

    lines.select{|cmd|
      (ip - MAIN_DUMP_WIDTH) <= cmd[:i] &&
        cmd[:i] <= (ip + MAIN_DUMP_WIDTH)
    }.map{|cmd|
      head =
        case cmd[:i]
        when ip
          "#{Escseq::INVERT}ip =>"
        else
          "     "
        end
      case cmd[:xs][0]
      when "_debug"
        head += Escseq::BLUE
      when "call", "ret", "jump", "jump_eq", "jump_above", "jump_below"
        head += Escseq::RED
      end

      indent = 
        case cmd[:xs][0]
        when "label"
          ""
        else
          "  "
        end

      "%s %02d %s%s#{Escseq::RESET}" % [head, cmd[:i], indent, cmd[:xs].inspect]
    }.join("\n")
  end

  def dump_stack(sp, bp)
    lines = []
    @stack.each_with_index{|x, i|
      next if i < sp - 8
      next if i > bp + 8
      head =
        case i
        when sp
          if sp == bp
            "sp bp => "
          else
            "sp    => "
          end
        when bp
          "   bp => "
        else
          "         "
        end
      lines << head + "#{i} #{x.inspect}"
    }
    lines.join("\n")
  end

  def dump_arr_v1
    rows = @vram.each_slice(5).to_a
    rows.map{|cols|
      cols.map{|col| col == 1 ? "@" : "." }.join("")
    }.join("\n")
  end

  def format_cols(cols)
    cols.map{|col| col == 1 ? "@" : "." }.join("")
  end

  def dump_arr_v2
    rows = @vram.each_slice(5).to_a
    main = rows[0..4]
    buf = rows[5..9]

    (0..4).map{|li|
      format_cols(main[li])
    }.join("\n")
  end

  def dump_arr
    rows = @vram.each_slice(5).to_a
    main = rows[0..4]
    buf = rows[5..9]

    (0..4).map{|li|
      format_cols(main[li]) + " " + format_cols(buf[li])
    }.join("\n")
  end

end

class Cpu

  def initialize(mem, stack_size)
    @mem = mem

    @ip = 0

    # registers
    @reg_a = 0
    @reg_b = 0
    @reg_c = 0
    @reg_d = 0

    # flags
    @zf = 0
    @of = 0

    @sp = stack_size - 1 # スタックポインタ
    @bp = stack_size - 1 # ベースポインタ

    @step = 0
  end

  def set_sp(addr)
    raise "Stack over flow" if addr < 0
    @sp = addr
  end

  def load_program(path)
    @mem.main = YAML.load_file(path)
  end

  def start
    # 開始前状態
    dump
    $stdin.gets

    loop do
      @step += 1
      op = @mem.main[@ip]
      case op
      when "noop"
        @ip += 1
      when "set_reg_a"
        arg = @mem.main[@ip + 1]
        n = if arg.is_a? Integer
              arg
            else
              mem_get_val(arg)
            end
        set_reg_a(n)
        @ip += 2
      when "set_reg_b"
        n = @mem.main[@ip + 1]
        set_reg_b(n)
        @ip += 2
      when "set_reg_d"
        arg = @mem.main[@ip + 1]
        n = if arg.is_a? Fixnum
              arg
            else
              mem_get_val(arg)
            end
        set_reg_d(n)
        @ip += 2
      when "set_vram"
        arg1 = @mem.main[@ip + 1]
        arg2 = @mem.main[@ip + 2]

        n1 = if arg1.is_a? Integer
               arg1
             else
               mem_get_val(arg1)
             end
        n2 = if arg2.is_a? Integer
              arg2
            else
              mem_get_val(arg2)
            end

        @mem.vram[n1] = n2

        @ip += 3
      when "get_vram" # ai, dest
        arg1 = @mem.main[@ip + 1]
        arg2 = @mem.main[@ip + 2]

        ai = if arg1.is_a? Integer
               arg1
             else
               mem_get_val(arg1)
             end
        val = @mem.vram[ai]

        case arg2
        when "reg_a"
          @reg_a = val
        else
          not_yet_impl(arg2)
        end
        
        @ip += 3
      when "label"
        @ip += 2
      when "jump"
        addr = @mem.main[@ip + 1]
        @ip = addr
      when "compare"
        compare()
        @ip += 1
      when "compare_v2"
        compare_v2()
        @ip += 1
      when "jump_eq"
        addr = @mem.main[@ip + 1]
        jump_eq(addr)
      when "jump_above"
        addr = @mem.main[@ip + 1]
        jump_above(addr)
      when "jump_below"
        addr = @mem.main[@ip + 1]
        jump_below(addr)
      when "exit"
        puts "exit"
        # pp self
        exit
      when "call"
        # sp を1減らす
        set_sp(@sp - 1)
        # 次の命令のアドレスをスタックに積む
        next_of_call = @ip + 2
        @mem.stack[ @sp ] = @ip + 2
        # call 先にジャンプ
        @ip = @mem.main[ @ip + 1 ]
      when "ret"
        # 戻りアドレス取得
        ret_addr = @mem.stack[ @sp ]
        # 戻る
        @ip = ret_addr
        # スタックを pop
        set_sp(@sp + 1)
      when "push"
        next_val = @mem.main[@ip + 1]
        val_to_push =
          case next_val
          when Integer
            next_val
          when "bp"
            @bp
          when /^\d+$/
            next_val
          when /^\[(.+)\]$/
            get_val($1)
          else
            raise "not yet impl"
          end
        @mem.stack[@sp - 1] = val_to_push
        set_sp(@sp - 1)
        @ip += 2
      when "pop"
        case @mem.main[@ip + 1]
        when "bp"
          @bp = @mem.stack[@sp]
        else
          raise "not yet impl"
        end
        set_sp(@sp + 1)
        @ip += 2
      when "cp"
        copy
        @ip += 3
      when "add_ab" # deprecated
        warn "add_ab is deprecated"
        assert_num(@reg_a)
        assert_num(@reg_b)
        @reg_c = @reg_a.to_i + @reg_b.to_i
        @ip += 1
      when "add_ab_v2"
        assert_num(@reg_a)
        assert_num(@reg_b)
        @reg_a = @reg_a.to_i + @reg_b.to_i
        @ip += 1
      when "sub_ab"
        assert_num(@reg_a)
        assert_num(@reg_b)
        @reg_a = @reg_a.to_i - @reg_b.to_i
        @ip += 1
      when "mult_ab"
        assert_num(@reg_a)
        assert_num(@reg_b)
        @reg_a = @reg_a.to_i * @reg_b.to_i
        @ip += 1
      when "add"
        arg1 = @mem.main[@ip + 1]
        arg2 = @mem.main[@ip + 2]
        case arg1
        when "sp"
          set_sp(@sp + arg2.to_i)
        else
          raise "not yet impl"
        end
        @ip += 3
      when "sub"
        arg1 = @mem.main[@ip + 1]
        arg2 = @mem.main[@ip + 2]
        case arg1
        when "sp"
          set_sp(@sp - arg2.to_i)
        else
          raise "not yet impl"
        end
        @ip += 3
      when "_debug"
        @ip += 2
      else
        raise "unknown operator (#{op})"
      end

      # dump_v2
      dump if @step % 20 == 0
      # sleep 1
      $stdin.gets if @step > 10000000
    end
  end

  def mem_get_val(addr)
    case addr
    when /^\[(.+)\]$/
      get_val($1)
    else
      raise not_yet_impl(addr)
    end
  end

  def get_val(arg)
    case arg
    when /^bp\+(\d+)$/
      stack_addr = @bp + $1.to_i
      @mem.stack[stack_addr]
    when /^bp\-(\d+)$/
      stack_addr = @bp - $1.to_i
      @mem.stack[stack_addr]
    else
      raise "not yet impl (#{arg})"
    end
  end

  def assert_num(x)
    case x
    when String
      if /^\d+$/ !~ x
        raise "must be number"
      end
    end
  end

  def set_val(dest, val)
    case dest
    when /^bp\-(\d+)$/
      stack_addr = @bp - $1.to_i
      @mem.stack[stack_addr] = val
    else
      raise "not yet impl"
    end
  end

  def copy
    arg1 = @mem.main[@ip+1]
    arg2 = @mem.main[@ip+2]

    src_val =
      case arg1
      when Fixnum
        arg1
      when "reg_a"
        @reg_a
      when "reg_b"
        @reg_b
      when "reg_c"
        @reg_c
      when "reg_d"
        @reg_d
      when "sp"
        @sp
      when "bp"
        @bp
      when /^\[(.+)\]$/
        get_val($1)
      when /^arr\[(\d+)\]$/
        idx = $1.to_i
        @mem.vram[idx]
      when /^(\d+)$/
        $1.to_i
      else
        raise "not yet impl"
      end

    case arg2
    when "reg_a"
      @reg_a = src_val
    when "reg_b"
      @reg_b = src_val
    when "reg_c"
      @reg_c = src_val
    when "reg_d"
      @reg_d = src_val
    when "sp"
      set_sp(src_val)
    when "bp"
      @bp = src_val
    when /^\[(.+)\]$/
      set_val($1, src_val)
    when /^arr\[(\d+)\]$/
      idx = $1.to_i
      @mem.vram[idx] = src_val
    else
      raise not_yet_impl(arg2)
    end
  end

  def dump
    puts <<-EOB
================================
#{@step}: #{dump_reg()} zf(#{@zf}) of(#{@of})
---- memory ---- ip(#{@ip})
#{ @mem.dump_main(@ip) }
---- memory (stack) ---- sp(#{@sp}) bp(#{@bp})
#{ @mem.dump_stack(@sp, @bp) }
---- memory (array) ----
#{ @mem.dump_arr() }
    EOB
  end

  def dump_v2
    puts <<-EOB

-----

#{ @mem.dump_arr_v2() }
    EOB
  end

  def dump_reg
    [
      "reg_a(#{@reg_a.inspect})",
      "reg_b(#{@reg_b.inspect})",
      "reg_c(#{@reg_c.inspect})",
      "reg_d(#{@reg_d.inspect})"
    ].join(" ")
  end

  def copy_mem_to_reg_a(mem_addr)
    @reg_a = @mem.main[mem_addr]
  end

  def copy_mem_to_reg_b(mem_addr)
    @reg_b = @mem.main[mem_addr]
  end

  def copy_reg_c_to_mem(mem_addr)
    @mem.main[mem_addr] = @reg_c
  end

  def set_mem(addr, n)
    @mem.main[addr] = n
  end

  def add_a_b
    temp = @reg_a + @reg_b
    if temp >= 16
      @reg_c = temp - 16
      @of = 1
    else
      @reg_c = temp
      @of = 0
    end
  end

  def set_reg_a(n)
    @reg_a = n
  end

  def set_reg_b(n)
    @reg_b = n
  end

  def set_reg_d(n)
    @reg_d = n
  end

  def compare
    @zf = (@reg_a == @reg_b ? 1 : 0)
  end

  def compare_v2
    delta = @reg_b - @reg_a
    case
    when delta > 0 # a < b
      @cf, @zf = 0, 0
    when delta < 0 # b < a
      @cf, @zf = 1, 0
    when delta == 0 # a == b
      @cf, @zf = 0, 1
    else
      raise "must not happen"
    end
  end

  def jump_eq(addr)
    if @zf == 1
      @ip = addr
    else
      @ip += 2
    end
  end

  def jump_above(addr)
    if @cf == 0 && @zf == 0
      @ip = addr
    else
      @ip += 2
    end
  end

  def jump_below(addr)
    if @cf == 1
      @ip = addr
    else
      @ip += 2
    end
  end

end

class Computer

  def initialize
    stack_size = 40
    mem = Memory.new(stack_size)
    @cpu = Cpu.new(mem, stack_size)
  end

  def start(bin_file)
    @cpu.load_program(bin_file)
    @cpu.start
  end

end

bin_file = ARGV[0]

computer = Computer.new
computer.start(bin_file)
