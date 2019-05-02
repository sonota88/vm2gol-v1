def p_e(*args)
  args.each{|arg| $stderr.puts arg.inspect }
end

def pp_e(*args)
  args.each{|arg| $stderr.puts arg.pretty_inspect }
end

def not_yet_impl(*args)
  msg = "not yet impl"
  args.each{|arg| msg += "(#{ arg.inspect })" }
  msg
end
