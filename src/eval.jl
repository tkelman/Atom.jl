using CodeTools, LNR, Media, Requires

import CodeTools: getblock, getthing

LNR.cursor(data::Associative) = cursor(data["row"], data["column"])

exit_on_sigint(on) = ccall(:jl_exit_on_sigint, Void, (Cint,), on)

function modulenames(data, pos)
  main = haskey(data, "module") ? data["module"] :
         haskey(data, "path") ? CodeTools.filemodule(data["path"]) :
         "Main"
  main == "" && (main = "Main")
  sub = CodeTools.codemodule(data["code"], pos)
  main, sub
end

function getmodule(data, pos)
  main, sub = modulenames(data, pos)
  getthing("$main.$sub", getthing(main, Main))
end

handle("module") do data
  main, sub = modulenames(data, cursor(data))
  return d(:main => main,
            :sub  => sub,
            :inactive => (getthing(main) == nothing),
            :subInactive => (getthing("$main.$sub") == nothing))
end

handle("allmodules") do
  sort!([string(m) for m in CodeTools.allchildren(Main)])
end

isselection(data) = data["start"] ≠ data["stop"]

macro errs(ex)
  :(try
      $(esc(ex))
    catch e
      EvalError(e.error, catch_backtrace())
    end)
end

const evallock = ReentrantLock()

function Base.lock(f::Function, l::ReentrantLock)
  lock(l)
  try return f()
  finally unlock(l) end
end

withpath(f, path) =
  Requires.withpath(f, path == nothing || isuntitled(path) ? nothing : path)

handle("eval") do data
  @destruct [code, [row] = start, stop, path || "untitled"] = data
  lock(evallock) do
    @dynamic let Media.input = Editor()
      mod = getmodule(data, cursor(start))
      block, (start, stop) = isselection(data) ?
                               getblock(code, cursor(start), cursor(stop)) :
                               getblock(code, row)
      isempty(block) && return d()
      !isselection(data) && msg("show-block", d(:start=>start, :end=>stop))
      result = withpath(path) do
        @errs include_string(mod, block, path, start)
      end
      display = Media.getdisplay(typeof(result), default = Editor())
      display ≠ Editor() && render(display, result)
      d(:start => start,
        :end => stop,
        :result => render(Editor(), result))
     end
   end
end

handle("evalall") do data
  lock(evallock) do
    @dynamic let Media.input = Editor()
      @destruct [setmod = :module || nothing, path || "untitled", code] = data
      mod = Main
      if setmod ≠ nothing
        mod = getthing(setmod, Main)
      elseif isabspath(path)
        mod = getthing(CodeTools.filemodule(path), Main)
      end
      try
        withpath(path) do
          include_string(mod, code, path)
        end
      catch e
        @msg error(d(:msg => "Error evaluating $(basename(path))",
                     :detail => sprint(showerror, e, catch_backtrace()),
                     :dismissable => true))
      end
    end
    return
  end
end

handle("evalrepl") do data
  lock(evallock) do
    @dynamic let Media.input = Console()
      @destruct [mode || nothing, code] = data
      if mode == "shell"
        code = "run(`$code`)"
      elseif mode == "help"
        code = "@doc $code"
      end
      try
        withpath(nothing) do
          render(@errs eval(Main, :(include_string($code))))
        end
      catch e
        showerror(STDERR, e, catch_backtrace())
      end
      return
    end
  end
end

handle("docs") do code
  result = @errs include_string("@doc $code")
  d(:result => render(Editor(), result))
end

handle("methods") do word
  wordtype = try
    include_string("typeof($word)")
  catch
    Function
  end
  if wordtype == Function
    result = @errs include_string("methods($word)")
  elseif wordtype == DataType
    result = @errs include_string("methodswith($word)")
  end
  d(:result => render(Editor(), result))
end
