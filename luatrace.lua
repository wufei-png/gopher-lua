local DEFAULT_RECORDER = "luatrace.trace_file"


-- Check if the ffi is available, and get a handle on the c library's clock.
-- LuaJIT doesn't compile traces containing os.clock yet.
local ffi
if jit and jit.status and jit.status() then
  local ok
  ok, ffi = pcall(require, "ffi")
  if ok then
    ffi.cdef("unsigned long clock(void);") 
  else
    ffi = nil
  end
end

-- See if the c hook is available
local c_hook
do
  local ok
  ok, c_hook = pcall(require, "luatrace.c_hook")
  if not ok then
    c_hook = nil
  end
end


-- Stack counting --------------------------------------------------------------

local stack_depth                       -- How deep we think the stack is when we're in the hook

local function count_stack(start_depth)
  start_depth = (start_depth and (start_depth+1)) or 3
                                        -- the caller of the hook that called this
  for i = start_depth, 65536 do
    if not debug.getinfo(i, "l") then
      stack_depth = i - 3               -- The depth to the caller
      return
    end
  end
end


local function was_that_a_tailcall()
  if debug.getinfo(stack_depth+2, "l") then
    stack_depth = stack_depth + 1
    return false
  else
    return true
  end
end


-- Trace recording -------------------------------------------------------------

local recorder                          -- The thing that's recording traces
local current_line                      -- The line we currently think is active
local accumulated_us                    -- The microseconds we've accumulated for that line

local thread_map                        -- Map threads to numbers
local thread_count                      -- How many threads we've mapped
local watch_thread                      -- The thread we're trying to spot changing

local CALLEE_INDEX, CALLER_INDEX        -- The indexes used for getinfo depend on the hook we're using

local ACCUMULATE_TO_NEXT = -1
local do_record_time = true
local last_action 
-- Emit a trace if the current line has changed
-- and reset the current line and accumulated time
local function set_current_line(l)
    print("l",l,"current_line",current_line,"ACCUMULATE_TO_NEXT",ACCUMULATE_TO_NEXT,",accumulated_us",accumulated_us)
  if l ~= current_line then
    -- If current_line is ACCUMULATE_TO_NEXT then leave the time for the new
    -- current_line to pick up
    if current_line ~= ACCUMULATE_TO_NEXT and accumulated_us > 0 then
      print("set_current_line recoder")
      recorder.record(current_line, do_record_time and accumulated_us or 0)
      accumulated_us = 0
    end
    current_line = l
  end
end


-- We only trace Lua functions
local function should_trace(f)
  return f and f.source:sub(1,1) == "@" and f.source:sub(-12) ~= "luatrace.lua" and f.source:sub(-14) ~= "trace_file.lua"
end


-- Record an action reported to the hook.
local function record(action, line, time)
  accumulated_us = accumulated_us + time

  if watch_thread then
    print("watch_thread",watch_thread)
    if action == "call" or action == "line" then
      local current_thread = coroutine.running() or "main"
      if watch_thread ~= current_thread then
        -- Get or make up the thread id
        local thread_id = thread_map[current_thread]
        if not thread_id then
          thread_count = thread_count + 1
          thread_map[current_thread] = thread_count
          thread_id = thread_count
        end
        -- Flush any time remaining on the caller
        print("set_current_line2",ACCUMULATE_TO_NEXT)

        set_current_line(ACCUMULATE_TO_NEXT)
        -- Record a resume
        recorder.record("R", thread_id)
        count_stack()
        if action == "call" then
          stack_depth = stack_depth - 1         -- so it looks like we're calling into the new thread
        end
      end
      watch_thread = nil
    end
  end

  if action == "line" then
    print("action line start")
    local callee = debug.getinfo(CALLEE_INDEX, "Sln")
    local caller = debug.getinfo(CALLER_INDEX, "Sl")
    if caller then
      print("action line caller",caller.short_src,caller.currentline)
    end
    if callee then
      print("action line callee",callee.short_src,callee.currentline,callee.lastlinedefined)
    end
    print("callee",callee.short_src,callee.currentline)
    if should_trace(callee)then
      count_stack()
      print("set_current_line action line")
      set_current_line(line)
    if last_action == "call" then
      print("bugfix")
      recorder.record(">", callee.short_src, callee.linedefined, callee.lastlinedefined)
    end
    end
  elseif action == "call" or action == "return" then
    local callee = debug.getinfo(CALLEE_INDEX, "Sln")
    local caller = debug.getinfo(CALLER_INDEX, "Sl")
    if caller then
      print("caller",caller.short_src,caller.currentline)
    end
    if callee then
      print("callee",callee.short_src,callee.currentline,callee.lastlinedefined)
    end
    if action == "call" then
      if caller==nil and callee~=nil then
        -- caller=callee
        -- callee=debug.getinfo(CALLER_INDEX, "Sl")
        return
      end

      local c = was_that_a_tailcall() and "T" or ">"
      if should_trace(caller) then
        -- square up the caller's time to the last line executed
        print("set_current_line action call caller",caller.currentline)
        set_current_line(caller.currentline)
      end
      if should_trace(callee) then
        -- start charging the callee for time, and record where we're going
        print("set_current_line action call callee",callee.currentline)
        set_current_line(callee.currentline)
        recorder.record(c, callee.short_src, callee.linedefined, callee.lastlinedefined)
      end
      if callee and callee.source == "=[C]" then
        if callee.name == "yield" then
          -- We don't know where we're headed yet (if yield gets renamed, all
          -- bets are off)
          set_current_line(ACCUMULATE_TO_NEXT)
          recorder.record("Y")
        elseif callee.name == "pcall" or callee.name == "xpcall" then
          set_current_line(ACCUMULATE_TO_NEXT)
          recorder.record("P")
        elseif callee.name == "error" then
          set_current_line(ACCUMULATE_TO_NEXT)
          recorder.record("E")
        elseif callee.name == "resume" then
          set_current_line(ACCUMULATE_TO_NEXT)
          recorder.record("P")                  -- resume is protected
          -- Watch the current thread and catch it if it changes.
          watch_thread = coroutine.running() or "main"          
        else                                    -- this might be a resume!
          -- Because of coroutine.wrap, any c function could resume a different
          -- thread.  Watch the current thread and catch it if it changes.
          watch_thread = coroutine.running() or "main"
        end
      end

    else -- action == "return"
      stack_depth = stack_depth - 1

      if should_trace(callee) then
        -- square up the callee's time to the last line executed
        -- print("callee:source()",callee.source,callee.currentline)
        print("set_current_line action return callee",callee.currentline)
        set_current_line(callee.currentline)
      end
      print("caller",type(caller),caller==nil)
      if caller then
          -- for k, v in pairs(caller) do
          --     print(k, v)
          -- end
          print(caller.source)
          print(caller.currentline)
      end
      if not caller                             -- final return from a coroutine
        or caller.source == "=(tail call)" then -- about to get tail-returned
        -- In both cases, there's no point recording time until we're
        -- back on our feet
        print("set_current_line3",ACCUMULATE_TO_NEXT)
        set_current_line(ACCUMULATE_TO_NEXT)
      elseif watch_thread and callee and callee.source == "=[C]" and callee.name == "yield" then
        -- Don't trace returns from yields, even into traceable functions.
        -- We'll catch them later with watch_thread
      elseif should_trace(caller) then
        -- The caller gets charged for time from here on
        print("set_current_line4",caller.currentline)
        set_current_line(caller.currentline)
      else
        -- Otherwise charge the time to the next line.  I'm not sure it's right
        -- but we have to set it to something
        -- set_current_line(ACCUMULATE_TO_NEXT)
      end
      if should_trace(callee) then
        recorder.record("<")
      end
      if not caller then                        -- final return from a coroutine,
        recorder.record("Y")                    -- looks like a yield
      end
    end

  elseif action == "tail return" then
    stack_depth = stack_depth - 1
    local caller = debug.getinfo(CALLER_INDEX, "Sl")
    -- If we've got a real caller, we're heading back to non-tail-call land
    -- start charging the caller for time
    if should_trace(caller) then
      print("set_current_line6",caller.currentline)
      set_current_line(caller.currentline)
    end
    recorder.record("<")
  end
end


-- The hooks -------------------------------------------------------------------

-- The Lua version of the hook uses os.clock
-- The LuaJIT version of the hook uses ffi.C.clock

local time_out                          -- Time we last left the hook

-- The hook - note the time and record something
local function hook_lua(action, line)
  print("hook_lua debug",action, line)
  local time_in = os.clock()
  -- print("record", action, line, (time_in - time_out) * 1000000)
  record(action, line, (time_in - time_out) * 1000000)
  time_out = os.clock()
  last_action = action
end
local function hook_luajit(action, line)
  local time_in = ffi.C.clock()
  record(action, line, time_in - time_out)
  time_out = ffi.C.clock()
end


-- Starting the hook - we go to unnecessary trouble to avoid reporting the
-- first few lines, which are inside and returning from luatrace.tron
local start_short_src, start_line

local function init_trace(line)

  -- Try to record the stack so far
  local depth = 2
  while true do
    depth = depth + 1
    local frame = debug.getinfo(depth, "S")
    if not frame then break end
  end
  for i = depth-1, 3, -1 do
    local frame = debug.getinfo(i, "Sln")
    if should_trace(frame) then
      recorder.record(">", frame.short_src, frame.linedefined, frame.lastlinedefined)
    end
  end

  -- Record the current thread
  thread_map, thread_count = { [coroutine.running() or "main"] = 1 }, 1

  count_stack()
  stack_depth = stack_depth - 1
  print("init_trace line",line)
  current_line, accumulated_us = -1, 0
end

local function hook_lua_start(action, line)
  local callee = debug.getinfo(2, "Sl")
  -- print("hook_start2",callee.short_src,callee.linedefined)
  -- callee=debug.getinfo(3, "Sl")
  -- print("hook_start3",callee.short_src,callee.linedefined)
  -- callee=debug.getinfo(4, "Sl")
  -- print("hook_start4",callee.short_src,callee.linedefined)
  io.stderr:write("luatrace: tracing with Lua hook\n")
  init_trace(line)
  CALLEE_INDEX, CALLER_INDEX = 3, 4
  time_out = os.clock()
  debug.sethook(hook_lua, "crl")
end
local function hook_luajit_start(action, line)
  io.stderr:write("luatrace: tracing with FFI hook\n")
  init_trace(line)
  CALLEE_INDEX, CALLER_INDEX = 3 ,4
  debug.sethook(hook_luajit, "crl")
  time_out = ffi.C.clock()
end
local function hook_c_start(action, line)
  io.stderr:write("luatrace: tracing with C hook\n")
  init_trace(line)
  CALLEE_INDEX, CALLER_INDEX = 2, 3
  c_hook.set_hook(record)
end


local function hook_start()
  local callee = debug.getinfo(2, "Sl")
  print("hook_start2",callee.short_src,callee.linedefined,start_short_src,start_line)
  if callee.short_src == start_short_src and callee.linedefined == start_line then
    if c_hook then
      debug.sethook(hook_lua_start, "l")
     -- debug.sethook(hook_lua_start, "l")
    elseif ffi then
      debug.sethook(hook_luajit_start, "l")
    else
      debug.sethook(hook_lua_start, "l")
      -- hook_lua_start("", "l")
    end
  end
end


-- Shutting down ---------------------------------------------------------------

local luatrace_exit_trick_file_name = os.tmpname()
local luatrace_raw_exit = os.exit


local function luatrace_on_exit()
  debug.sethook()
  if recorder then
    recorder.close()
  end
  os.remove(luatrace_exit_trick_file_name)
end


local function luatrace_exit_trick()
  luatrace_exit_trick_file = io.open(luatrace_exit_trick_file_name, "w")
  debug.setmetatable(luatrace_exit_trick_file, { __gc = luatrace_on_exit } )
  os.exit = function(...)
    luatrace_on_exit()
    luatrace_raw_exit(...)
  end
end


-- API Functions ---------------------------------------------------------------

local luatrace = {}

local defaults =
{
  recorder = DEFAULT_RECORDER,
}

-- Turn the tracer on
function luatrace.tron(settings)
  settings = settings or {}
  for k, v in pairs(defaults) do
    if not settings[k] then settings[k] = v end
  end

  if type(settings.recorder) == "string" then
    recorder = require(settings.recorder)
  else
    recorder = settings.recorder
  end
  assert(recorder, "couldn't find the trace recorder")
  recorder.open(settings)

  if settings.record_time ~= nil then do_record_time = settings.record_time end

  local me = debug.getinfo(1, "Sl")
  start_short_src, start_line = me.short_src, me.linedefined
  -- local trondebug = debug.getinfo(2, "Sl")
  -- print("trondebug",trondebug.short_src,trondebug.lastlinedefined)
  luatrace_exit_trick()

  debug.sethook(hook_start, "r")
end


-- Turn it off and close the recorder
function luatrace.troff()
  if recorder then
    debug.sethook()
    recorder.close()
    recorder = nil
    os.remove(luatrace_exit_trick_file_name)
    os.exit = luatrace_raw_exit
  end
end


-- Set defaults for the Luatrace (handy on the command line!)
function luatrace.set_defaults(d)
  for k, v in pairs(d) do
    defaults[k] = v
  end
end


return luatrace

-- EOF -------------------------------------------------------------------------

