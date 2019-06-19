(**************************************************************************)
(*     Sail                                                               *)
(*                                                                        *)
(*  Copyright (c) 2013-2017                                               *)
(*    Kathyrn Gray                                                        *)
(*    Shaked Flur                                                         *)
(*    Stephen Kell                                                        *)
(*    Gabriel Kerneis                                                     *)
(*    Robert Norton-Wright                                                *)
(*    Christopher Pulte                                                   *)
(*    Peter Sewell                                                        *)
(*    Alasdair Armstrong                                                  *)
(*    Brian Campbell                                                      *)
(*    Thomas Bauereiss                                                    *)
(*    Anthony Fox                                                         *)
(*    Jon French                                                          *)
(*    Dominic Mulligan                                                    *)
(*    Stephen Kell                                                        *)
(*    Mark Wassell                                                        *)
(*                                                                        *)
(*  All rights reserved.                                                  *)
(*                                                                        *)
(*  This software was developed by the University of Cambridge Computer   *)
(*  Laboratory as part of the Rigorous Engineering of Mainstream Systems  *)
(*  (REMS) project, funded by EPSRC grant EP/K008528/1.                   *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*     notice, this list of conditions and the following disclaimer.      *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*     notice, this list of conditions and the following disclaimer in    *)
(*     the documentation and/or other materials provided with the         *)
(*     distribution.                                                      *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''    *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED     *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A       *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR   *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,          *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT      *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF      *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND   *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT    *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF    *)
(*  SUCH DAMAGE.                                                          *)
(**************************************************************************)

open Ast
open Ast_util
open Jib
open Jib_util
open Value2

module StringMap = Map.Make(String)

type global_state = {
    functions : (calling_convention * id list * instr array * int StringMap.t) Bindings.t
  }

let empty_global_state = {
    functions = Bindings.empty
  }

let rec make_jump_table n jt = function
  | I_aux (I_label label, _) :: instrs ->
     make_jump_table (n + 1) (StringMap.add label n jt) instrs
  | _ :: instrs ->
     make_jump_table (n + 1) jt instrs
  | [] -> jt

let initialize_global_state cdefs =
  let rec init gstate = function
    | CDEF_fundef (id, cc, args, instrs) :: defs ->
       let instrs = Jib_optimize.flatten_instrs instrs in
       let jump_table = make_jump_table 0 StringMap.empty instrs in
       init { functions = Bindings.add id (cc, args, Array.of_list instrs, jump_table) gstate.functions } defs
    | _ :: defs ->
       init gstate defs
    | [] -> gstate
  in
  init empty_global_state cdefs

module IntMap = Map.Make(struct type t = int let compare = compare end)

type stack = {
    pc: int;
    locals: vl NameMap.t;
    match_state: (int * string) list IntMap.t;
    current_cc: calling_convention;
    instrs: instr array;
    jump_table: int StringMap.t;
    calls: string list;
    pop: (vl -> stack) option
  }

let initialize_stack instrs = {
    pc = 0;
    locals = NameMap.empty;
    match_state = IntMap.empty;
    current_cc = CC_stack;
    instrs = Array.of_list instrs;
    jump_table = make_jump_table 0 StringMap.empty instrs;
    calls = [];
    pop = None
  }

let string_of_local (name, v) = Util.(string_of_name ~zencode:false name |> green |> clear) ^ " => " ^ string_of_value v

let print_stack stack =
  let banner = "====================================================" in
  print_endline ("Calls: " ^ Util.string_of_list ", " (fun x -> x) stack.calls);
  print_endline banner;
  let pc = string_of_int stack.pc ^ " -> " in
  let margin = String.make (String.length pc) ' ' in
  for i = stack.pc - 10 to stack.pc - 1 do
    if i >= 0 then
      let instr = stack.instrs.(i) in
      print_endline (margin ^ Pretty_print_sail.to_string (pp_instr instr))
    else ()
  done;
  print_endline (pc ^ Pretty_print_sail.to_string (pp_instr stack.instrs.(stack.pc)));
  for i = stack.pc + 1 to stack.pc + 10 do
    if i < Array.length stack.instrs then
      let instr = stack.instrs.(i) in
      print_endline (margin ^ Pretty_print_sail.to_string (pp_instr instr))
    else ()
  done;
  print_endline banner;
  print_endline (Util.string_of_list ", " string_of_local (NameMap.bindings stack.locals));
  if IntMap.cardinal stack.match_state > 0 then (
    print_endline Util.("matches:" |> cyan |> clear);
    List.iter (fun (uid, groups) ->
        print_endline (string_of_int uid ^ ": " ^ Util.string_of_list " " (fun (group, str) -> Printf.sprintf "(%d, \"%s\")" group str) groups)
      ) (IntMap.bindings stack.match_state)
  ) else ()

let evaluate_cval_call f vls =
  let open Sail2_operators_bitlists in
  match f, vls with
  | Bnot, [VL_bool b] -> VL_bool (not b)
  | Bor, [VL_bool a; VL_bool b] -> VL_bool (a || b)
  | Band, [VL_bool a; VL_bool b] -> VL_bool (a && b)
  | Eq, [v1; v2] -> VL_bool (v1 = v2)
  | Neq, [v1; v2] -> VL_bool (not (v1 = v2))
  | Ilt, [VL_int x; VL_int y] -> VL_bool (x < y)
  | Ilteq, [VL_int x; VL_int y] -> VL_bool (x <= y)
  | Igt, [VL_int x; VL_int y] -> VL_bool (x > y)
  | Igteq, [VL_int x; VL_int y] -> VL_bool (x >= y)
  | Iadd, [VL_int x; VL_int y] -> VL_int (Big_int.add x y)
  | Isub, [VL_int x; VL_int y] -> VL_int (Big_int.sub x y)
  | Unsigned _, [VL_bits (bv, ord)] -> VL_int (uint bv)
  | Signed _, [VL_bits (bv, ord)] -> VL_int (sint bv)
  | Bvnot, [VL_bits (bv, ord)] -> VL_bits (not_vec bv, ord)
  | Bvand, [VL_bits (bv1, ord1); VL_bits (bv2, ord2)] when ord1 = ord2 -> VL_bits (and_vec bv1 bv2, ord1)
  | Bvor, [VL_bits (bv1, ord1); VL_bits (bv2, ord2)] when ord1 = ord2 -> VL_bits (or_vec bv1 bv2, ord1)
  | Bvxor, [VL_bits (bv1, ord1); VL_bits (bv2, ord2)] when ord1 = ord2 -> VL_bits (xor_vec bv1 bv2, ord1)
  | Bvadd, [VL_bits (bv1, ord1); VL_bits (bv2, ord2)] when ord1 = ord2 -> VL_bits (add_vec bv1 bv2, ord1)
  | Bvsub, [VL_bits (bv1, ord1); VL_bits (bv2, ord2)] when ord1 = ord2 -> VL_bits (sub_vec bv1 bv2, ord1)
  | Concat, [VL_bits (bv1, ord1); VL_bits (bv2, ord2)] when ord1 = ord2 -> VL_bits (concat_vec bv1 bv2, ord1)
  | Zero_extend n, [VL_bits (bv, ord)] -> VL_bits (extz_vec (Big_int.of_int n) bv, ord)
  | Sign_extend n, [VL_bits (bv, ord)] -> VL_bits (exts_vec (Big_int.of_int n) bv, ord)
  | _ -> failwith "Unsupported cval function"

let rec evaluate_cval locals = function
  | V_id (name, _) ->
     begin match NameMap.find_opt name locals with
     | Some vl -> vl
     | None -> VL_null
     end
  | V_call (f, vls) -> evaluate_cval_call f (List.map (evaluate_cval locals) vls)
  | V_lit (vl, _) -> vl
  | cval -> VL_null

let eval_extern name args stack =
  match name, args with
  | "sail_regmatch", [VL_string regex; VL_string input; VL_matcher (n, uid)] ->
     let regex = Str.regexp regex in
     if Str.string_match regex input 0 then (
       let groups = List.init n (fun i -> (i + 1, Str.matched_group (i + 1) input)) in
       VL_bool true, { stack with match_state = IntMap.add uid groups stack.match_state }
     ) else (
       VL_bool false, stack
     )
  | "sail_getmatch", [VL_string _ (* input *); VL_matcher (n, uid); VL_int m] ->
     let groups = IntMap.find uid stack.match_state in
     VL_string (List.assoc (Big_int.to_int m) groups), stack

  | _ ->
     failwith "Unknown extern call"

type step =
  | Step of stack
  | Done of vl

let global_unique_number = ref (-1)

let unique_number () =
  incr global_unique_number;
  !global_unique_number

let rec declaration = function
  | CT_lint -> VL_int Big_int.zero
  | CT_fint _ -> VL_int Big_int.zero
  | CT_constant n -> VL_int n
  | CT_lbits ord -> VL_bits ([], ord)
  | CT_sbits (_, ord) -> VL_bits ([], ord)
  | CT_fbits (n, ord) -> VL_bits (List.init n (fun _ -> Sail2_values.B0), ord)
  | CT_unit -> VL_unit
  | CT_bool -> VL_bool false
  | CT_bit -> VL_bit Sail2_values.B0
  | CT_string -> VL_string ""
  | CT_real -> VL_real "0.0"
  | CT_tup ctyps -> VL_tuple (List.map declaration ctyps)
  | CT_match n -> VL_matcher (n, unique_number ())
  | _ -> VL_null

let set_tuple tup n v =
  match tup with
  | VL_tuple vs -> VL_tuple (Util.take n vs @ [v] @ Util.drop (n + 1) vs)
  | _ -> failwith "Non tuple passed to set_tuple"

let assignment clexp v stack =
  match clexp with
  | CL_id (id, _) -> { stack with locals = NameMap.add id v stack.locals }
  | CL_tuple (CL_id (id, ctyp), n) ->
     let tup = match NameMap.find_opt id stack.locals with
       | Some v -> v
       | None -> declaration ctyp
     in
     { stack with locals = NameMap.add id (set_tuple tup n v) stack.locals }
  | _ -> failwith "Unhandled c-lexp"

let step global_state stack =
  let pc = stack.pc in
  match stack.instrs.(pc) with
  | I_aux (I_decl (ctyp, id), _) ->
     Step { stack with locals = NameMap.add id (declaration ctyp) stack.locals; pc = pc + 1 }

  | I_aux (I_init (ctyp, id, cval), _) ->
     let v = evaluate_cval stack.locals cval in
     Step { stack with locals = NameMap.add id v stack.locals; pc = pc + 1 }

  | I_aux (I_jump (cval, label), _) ->
     let v = evaluate_cval stack.locals cval in
     begin match v with
     | VL_bool true ->
        Step { stack with pc = StringMap.find label stack.jump_table }
     | VL_bool false ->
        Step { stack with pc = pc + 1 }
     | _ -> failwith "Jump argument did not evaluate to boolean"
     end

  | I_aux (I_funcall (clexp, false, id, args), _) ->
     let args = List.map (evaluate_cval stack.locals) args in
     let cc, params, body, jump_table = Bindings.find id global_state.functions in
     Step {
       pc = 0;
       locals = List.fold_left2 (fun locals param arg -> NameMap.add (name param) arg locals) NameMap.empty params args;
       match_state = IntMap.empty;
       current_cc = cc;
       instrs = body;
       jump_table = jump_table;
       calls = string_of_id id :: stack.calls;
       pop = Some (fun v -> assignment clexp v stack)
     }

  | I_aux (I_funcall (clexp, true, id, args), _) ->
     let args = List.map (evaluate_cval stack.locals) args in
     let v, stack' = eval_extern (string_of_id id) args stack in
     Step { (assignment clexp v stack') with pc = pc + 1 }

  | I_aux (I_goto label, _) ->
     Step { stack with pc = StringMap.find label stack.jump_table }

  | I_aux (I_match_failure, _) -> failwith "Pattern match failure"

  | I_aux (I_copy (clexp, cval), _) ->
     let v = evaluate_cval stack.locals cval in
     Step { (assignment clexp v stack) with pc = pc + 1 }

  | _ -> Step { stack with pc = pc + 1 }
