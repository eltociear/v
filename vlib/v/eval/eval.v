// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module eval

import v.ast
import v.pref
import v.util

pub fn new_eval(table &ast.Table, pref &pref.Preferences) Eval {
	return Eval{
		table: table
		pref: pref
	}
}

// const/global is `Object`
type Symbol = Object | ast.EmptyStmt | ast.FnDecl

pub struct Eval {
	pref &pref.Preferences
pub mut:
	table                  &ast.Table
	mods                   map[string]map[string]Symbol
	future_register_consts map[string]map[string]map[string]ast.ConstField // mod:file:name:field
	local_vars             map[string]Var
	local_vars_stack       []map[string]Var
	scope_idx              int // this is increased when e.open_scope() is called, decreased when e.close_scope() (and all variables with that scope level deleted)
	returning              bool
	return_values          []Object
	cur_mod                string
	cur_file               string
	back_trace             []string
}

pub fn (mut e Eval) eval(files []&ast.File) {
	e.register_symbols(files)
	// println(files.map(it.path_base))
	e.run_func(e.mods['main']['main'] or { ast.EmptyStmt{} } as ast.FnDecl)
}

// first arg is reciever (if method)
pub fn (mut e Eval) run_func(func ast.FnDecl, _args ...Object) {
	e.back_trace << func.name
	old_mod := e.cur_mod
	e.cur_mod = func.mod

	old_file := e.cur_file
	e.cur_file = func.file
	defer {
		e.cur_mod = old_mod
		e.cur_file = old_file
		e.back_trace.pop()
	}
	mut args := _args.clone()
	if func.params.len != args.len && !func.is_variadic {
		e.error('mismatched parameter length for $func.name: got `$args.len`, expected `$func.params.len`')
	}

	if func.name in ['print', 'println', 'eprint', 'eprintln'] {
		s := args[0].string() // stringify because println accepts anything as argument
		match func.name {
			'print' {
				print(s)
			}
			'println' {
				println(s)
			}
			'eprint' {
				eprint(s)
			}
			'eprintln' {
				eprintln(s)
			}
			else {}
		}
	} else {
		e.local_vars_stack << e.local_vars
		e.local_vars = {}
		old_scope := e.scope_idx
		e.scope_idx = 0
		e.open_scope()
		// have to do this because of cgen error
		args__ := if func.is_method { args[1..] } else { args }
		for i, arg in args__ {
			e.local_vars[(func.params[i]).name] = Var{
				val: arg
				scope_idx: e.scope_idx
			}
		}
		if func.is_method {
			print(e.back_trace)
			println(func.receiver.typ - 65536)
			e.local_vars[func.receiver.name] = Var{
				val: args[0]
				scope_idx: e.scope_idx
			}
		}
		e.stmts(func.stmts)
		e.returning = false
		e.close_scope()
		e.scope_idx = old_scope
		e.local_vars = e.local_vars_stack.pop()
	}
}

pub fn (mut e Eval) register_symbols(files []&ast.File) {
	for file in files {
		// eprintln('registering file: $file.path_base')
		mod := file.mod.name
		e.register_symbol_stmts(file.stmts[1..], mod, file.path)

		// eprintln('registered file: $file.path_base')
	}
	for mod, const_files in e.future_register_consts {
		e.cur_mod = mod

		for file, fields in const_files {
			e.cur_file = file
			for _, field in fields {
				e.mods[mod][field.name.all_after_last('.')] = e.expr(field.expr, field.typ)
				if mod == 'os' && field.name.all_after_last('.') == 'args' {
					mut res := Array{}
					res.val << e.pref.out_name.all_after_last('/')
					for arg in e.pref.run_args {
						res.val << arg
					}
					e.mods[mod][field.name.all_after_last('.')] = Object(res)
				}
			}
		}
	}
}

pub fn (mut e Eval) register_symbol_stmts(stmts []ast.Stmt, mod string, file string) {
	for stmt in stmts { // first is just module declaration, so ignore
		e.register_symbol(stmt, mod, file)
	}
}

pub fn (mut e Eval) register_symbol(stmt ast.Stmt, mod string, file string) {
	match stmt {
		ast.FnDecl {
			// this mess because c error
			x := ast.Stmt(stmt)
			y := Symbol(x as ast.FnDecl)
			e.mods[mod][stmt.name.all_after_last('.')] = y
		}
		ast.Import {} // already handled by builder, TODO: get `as` name
		ast.StructDecl {} // these are already parsed by the checker into e.table
		ast.InterfaceDecl {}
		ast.EnumDecl {}
		ast.TypeDecl {}
		ast.GlobalDecl {}
		ast.HashStmt {}
		ast.ConstDecl {
			// evaluate them later since they may use functions defined after this point
			for field in stmt.fields {
				e.future_register_consts[mod][file][field.name] = field
			}
		}
		ast.ExprStmt {
			println('expr')
			x := stmt.expr
			match x {
				ast.IfExpr {
					if !x.is_comptime {
						e.error('only comptime ifs are allowed in top level')
					}
					for i, branch in x.branches {
						mut do_if := false
						println('branch:$branch')
						match (branch.cond as ast.Ident).name {
							'windows' {
								do_if = e.pref.os == .windows
							}
							else {
								e.error('unknown compile time if')
							}
						}
						do_if = do_if || x.branches.len == i + 1
						if do_if {
							e.register_symbol_stmts(branch.stmts, mod, file)
							break
						}
					}
				}
				else {
					e.error('unknown decleration expression statement $x.type_name()')
				}
			}
		}
		else {
			e.error('unhandled decleration statement $stmt.type_name()')
		}
	}
}

fn (e Eval) error(msg string) {
	util.verror('interpreter', msg)
}
