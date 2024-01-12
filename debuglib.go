package lua

import (
	"fmt"
	"strings"
)

func OpenDebug(L *LState) int {
	dbgmod := L.RegisterModule(DebugLibName, debugFuncs)
	L.Push(dbgmod)
	return 1
}

var debugFuncs = map[string]LGFunction{
	"getfenv":      debugGetFEnv,
	"getinfo":      debugGetInfo,
	"getlocal":     debugGetLocal,
	"getmetatable": debugGetMetatable,
	"getupvalue":   debugGetUpvalue,
	"setfenv":      debugSetFEnv,
	"setlocal":     debugSetLocal,
	"setmetatable": debugSetMetatable,
	"setupvalue":   debugSetUpvalue,
	"traceback":    debugTraceback,
	"sethook":      debugSetHook,
	"gethook":      debugGetHook,
}

func debugGetFEnv(L *LState) int {
	L.Push(L.GetFEnv(L.CheckAny(1)))
	return 1
}

func debugSetHook(L *LState) int {
	// L.CheckTypes(3, LTNumber)

	callbackArg := L.OptFunction(1, nil) //直接获取即可
	eventArg := L.OptString(2, "")       //直接获取即可
	countArg := L.OptInt(3, 0)
	if callbackArg != nil {
		L.Pop(1)
	}
	if eventArg != "" {
		L.Pop(1)
	}
	if countArg != 0 {
		L.Pop(1)
	}
	// print("callbackArg:", callbackArg, " eventArg:", eventArg, " countArg:", countArg, "\n")
	if callbackArg == nil || eventArg == "" {
		callbackArg = nil
		eventArg = "" //"callbackArg or eventArg is nil,turn off hooks
	}
	_ = L.SetHook(callbackArg, eventArg, countArg)
	return 0
}
func debugGetHook(L *LState) int {
	callback, eventArg, countArg := L.GetHook()
	if callback == nil {
		L.Push(LNil)
	} else {
		L.Push(callback)
	}
	L.Push(LString(eventArg))
	L.Push(LNumber(countArg))
	return 3
}

func debugGetInfo(L *LState) int {
	L.CheckTypes(1, LTFunction, LTNumber)
	arg1 := L.Get(1)
	what := L.OptString(2, "Slunf")
	var dbg *Debug
	var fn LValue
	var err error
	var ok bool
	switch lv := arg1.(type) {
	case *LFunction:
		dbg = &Debug{}
		fn, err = L.GetInfo(">"+what, dbg, lv)
	case LNumber:
		dbg, ok = L.GetStack(int(lv))
		if !ok {
			L.Push(LNil)
			return 1
		}
		fn, err = L.GetInfo(what, dbg, LNil)
	}

	if err != nil {
		L.Push(LNil)
		return 1
	}
	tbl := L.NewTable()
	if len(dbg.Name) > 0 {
		tbl.RawSetString("name", LString(dbg.Name))
	} else {
		tbl.RawSetString("name", LNil)
	}
	tbl.RawSetString("what", LString(dbg.What))
	tbl.RawSetString("source", LString("@"+dbg.Source))
	tbl.RawSetString("short_src", LString(dbg.Source))
	tbl.RawSetString("currentline", LNumber(dbg.CurrentLine))
	tbl.RawSetString("nups", LNumber(dbg.NUpvalues))
	tbl.RawSetString("linedefined", LNumber(dbg.LineDefined))
	tbl.RawSetString("lastlinedefined", LNumber(dbg.LastLineDefined))
	tbl.RawSetString("func", fn)
	L.Push(tbl)
	return 1
}

func debugGetLocal(L *LState) int {
	level := L.CheckInt(1)
	idx := L.CheckInt(2)
	dbg, ok := L.GetStack(level)
	if !ok {
		L.ArgError(1, "level out of range")
	}
	name, value := L.GetLocal(dbg, idx)
	if len(name) > 0 {
		L.Push(LString(name))
		L.Push(value)
		return 2
	}
	L.Push(LNil)
	return 1
}

func debugGetMetatable(L *LState) int {
	L.Push(L.GetMetatable(L.CheckAny(1)))
	return 1
}

func debugGetUpvalue(L *LState) int {
	fn := L.CheckFunction(1)
	idx := L.CheckInt(2)
	name, value := L.GetUpvalue(fn, idx)
	if len(name) > 0 {
		L.Push(LString(name))
		L.Push(value)
		return 2
	}
	L.Push(LNil)
	return 1
}

func debugSetFEnv(L *LState) int {
	L.SetFEnv(L.CheckAny(1), L.CheckAny(2))
	return 0
}

func debugSetLocal(L *LState) int {
	level := L.CheckInt(1)
	idx := L.CheckInt(2)
	value := L.CheckAny(3)
	dbg, ok := L.GetStack(level)
	if !ok {
		L.ArgError(1, "level out of range")
	}
	name := L.SetLocal(dbg, idx, value)
	if len(name) > 0 {
		L.Push(LString(name))
	} else {
		L.Push(LNil)
	}
	return 1
}

func debugSetMetatable(L *LState) int {
	L.CheckTypes(2, LTNil, LTTable)
	obj := L.Get(1)
	mt := L.Get(2)
	L.SetMetatable(obj, mt)
	L.SetTop(1)
	return 1
}

func debugSetUpvalue(L *LState) int {
	fn := L.CheckFunction(1)
	idx := L.CheckInt(2)
	value := L.CheckAny(3)
	name := L.SetUpvalue(fn, idx, value)
	if len(name) > 0 {
		L.Push(LString(name))
	} else {
		L.Push(LNil)
	}
	return 1
}

func debugTraceback(L *LState) int {
	msg := ""
	level := L.OptInt(2, 1)
	ls := L
	if L.GetTop() > 0 {
		if s, ok := L.Get(1).(LString); ok {
			msg = string(s)
		}
		if l, ok := L.Get(1).(*LState); ok {
			ls = l
			msg = ""
		}
	}

	traceback := strings.TrimSpace(ls.stackTrace(level))
	if len(msg) > 0 {
		traceback = fmt.Sprintf("%s\n%s", msg, traceback)
	}
	L.Push(LString(traceback))
	return 1
}
