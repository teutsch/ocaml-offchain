
open Merkle
open Ast
open Source
open Types

type control = {
  rets : int;
  level : int;
}

type context = {
  ptr : int;
  locals : int;
  bptr : int;
  stack : Int32.t list;
  f_types : (Int32.t, func_type) Hashtbl.t;
  f_types2 : (Int32.t, func_type) Hashtbl.t;
  block_return : control list;
}

let rec popn n = function
 | a::tl when n > 0 -> popn (n-1) tl
 | lst -> lst

let rec take n = function
 | a::tl when n > 0 -> a :: take (n-1) tl
 | lst -> []

let una_stack id x = {x with stack=id::popn 1 x.stack}
let bin_stack id x = {x with stack=id::popn 2 x.stack}
let n_stack n id x = {x with stack=id::popn n x.stack}

type extra = {
  mutable max_stack : int;
}

let do_it x f = {x with it=f x.it}
let it e = {it=e; at=no_region}


let rec compile e (ctx : context) expr = compile' e ctx (Int32.of_int expr.at.right.line) expr.it
and compile' e ctx id v =
  let res = compile'' e ctx id v in
  e.max_stack <- max e.max_stack (List.length ctx.stack);
  res
and compile'' e ctx id = function
 | Block (ty, lst) ->
   let rets = List.length ty in
   let extra = ctx.ptr - ctx.locals in
   if extra > 0 then trace ("block start " ^ string_of_int extra);
   let old_return = ctx.block_return in
   let old_ptr = ctx.ptr in
   let old_stack = ctx.stack in
   let ctx = {ctx with bptr=ctx.bptr+1; block_return={level=old_ptr+rets; rets=rets}::ctx.block_return} in
   let ctx = compile_block e ctx lst in
   if extra > 0 then trace ("block end");
   {ctx with bptr=ctx.bptr-1; block_return=old_return; ptr=old_ptr+rets; stack=make id rets @ old_stack}
 (* Loops have no return types currently *)
 | Loop (_, lst) ->
   let old_return = ctx.block_return in
   let extra = ctx.ptr - ctx.locals in
   if extra > 0 then trace ("loop start " ^ string_of_int extra);
   let ctx = {ctx with bptr=ctx.bptr+1; block_return={level=ctx.ptr; rets=0}::old_return} in
   let ctx = compile_block e ctx lst in
   if extra > 0 then trace ("loop end " ^ string_of_int extra);
   {ctx with bptr=ctx.bptr-1; block_return=old_return}
 | Call v ->
   (* Will just push the pc *)
   let FuncType (par,ret) = Hashtbl.find ctx.f_types v.it in
   let extra = ctx.ptr - ctx.locals - List.length par in
   if extra > 0 then trace ("call " ^ string_of_int extra);
   {ctx with ptr=ctx.ptr+List.length ret-List.length par; stack=make id (List.length ret) @ popn (List.length par) ctx.stack}
 | CallIndirect v ->
   let FuncType (par,ret) = Hashtbl.find ctx.f_types2 v.it in
   let extra = ctx.ptr - ctx.locals - List.length par - 1 in
   if extra > 0 then trace ("calli " ^ string_of_int extra);
   {ctx with ptr=ctx.ptr+List.length ret-List.length par-1; stack=make id (List.length ret) @ popn (List.length par + 1) ctx.stack}
 | If (ty, texp, fexp) ->
   let a_ptr = ctx.ptr-1 in
   let ctx = {ctx with ptr=a_ptr} in
   let ctx = compile' e ctx id (Block (ty, texp)) in
   let ctx = compile' e {ctx with ptr=a_ptr} id (Block (ty, fexp)) in
   ctx
 | Const lit -> {ctx with ptr = ctx.ptr+1; stack=id::ctx.stack}
 | Test t -> una_stack id ctx
 | Compare i -> bin_stack id {ctx with ptr = ctx.ptr-1}
 | Unary i -> una_stack id ctx
 | Binary i -> bin_stack id {ctx with ptr = ctx.ptr-1}
 | Convert i -> una_stack id ctx
 | Unreachable -> ctx
 | Nop -> ctx
 (* breaks might be used to return values, check this *)
 | Br x ->
   let num = Int32.to_int x.it in
   let c = List.nth ctx.block_return num in
   {ctx with ptr=ctx.ptr - c.rets; stack=popn c.rets ctx.stack}
 | BrIf x ->
   let num = Int32.to_int x.it in
   {ctx with ptr = ctx.ptr-1; stack=popn 1 ctx.stack}
 | BrTable (tab, def) ->
   let num = Int32.to_int def.it in
   let { rets; _ } = List.nth ctx.block_return num in
   {ctx with ptr = ctx.ptr-1-rets; stack=popn (rets+1) ctx.stack}
 | Return ->
   let num = ctx.bptr-1 in
   let {level=ptr; rets} = List.nth ctx.block_return num in
   {ctx with ptr=ctx.ptr - rets}
 | Drop -> {ctx with ptr=ctx.ptr-1}
 | GrowMemory -> {ctx with ptr=ctx.ptr-1; stack=popn 1 ctx.stack}
 | CurrentMemory -> {ctx with ptr=ctx.ptr+1; stack=id::ctx.stack}
 | GetGlobal x -> {ctx with ptr=ctx.ptr+1; stack=id::ctx.stack}
 | SetGlobal x -> {ctx with ptr=ctx.ptr-1; stack=popn 1 ctx.stack}
 | Select -> n_stack 3 id {ctx with ptr=ctx.ptr-2}
 | GetLocal v -> {ctx with ptr=ctx.ptr+1; stack=id::ctx.stack}
 | SetLocal v -> {ctx with ptr=ctx.ptr-1; stack=popn 1 ctx.stack}
 | TeeLocal v -> una_stack id ctx
 | Load op -> una_stack id ctx
 | Store op -> bin_stack id {ctx with ptr=ctx.ptr-2}

and compile_block e ctx = function
 | [] -> ctx
 | a::tl ->
    let ctx = compile e ctx a in
    let ctx = compile_block e ctx tl in
    ctx

let check_func ctx func =
   let e = {max_stack=0} in
   let FuncType (par,ret) = Hashtbl.find ctx.f_types2 func.it.ftype.it in
   (* Just params are now in the stack *)
   let locals = List.length par + List.length func.it.locals in
   let ctx = compile' e {ctx with ptr=locals; locals=locals} 0l (Block (ret, func.it.body)) in
   let limit = List.length func.it.locals + e.max_stack in
   prerr_endline ("" ^ string_of_int limit);
   limit

let check m =
   let ftab, ttab = Secretstack.make_tables m.it in
   let ctx = {
      ptr=0; bptr=0; block_return=[]; 
      f_types2=ttab; f_types=ftab;
      locals=0; stack=[] } in
   let lst = List.sort compare (List.map (fun x -> check_func ctx x) m.it.funcs) in
   if lst <> [] then prerr_endline ("Highest " ^ string_of_int (List.hd (List.rev lst)))


