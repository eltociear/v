// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module checker

import v.ast
import v.token

pub fn (mut c Checker) interface_decl(mut node ast.InterfaceDecl) {
	c.check_valid_pascal_case(node.name, 'interface name', node.pos)
	mut decl_sym := c.table.sym(node.typ)
	is_js := node.language == .js
	if mut decl_sym.info is ast.Interface {
		if node.ifaces.len > 0 {
			all_ifaces := c.expand_iface_embeds(node, 0, node.ifaces)
			// eprintln('> node.name: $node.name | node.ifaces.len: $node.ifaces.len | all_ifaces: $all_ifaces.len')
			node.ifaces = all_ifaces
			mut emnames := map[string]int{}
			mut emnames_ds := map[string]bool{}
			mut emnames_ds_info := map[string]bool{}
			mut efnames := map[string]int{}
			mut efnames_ds_info := map[string]bool{}
			for i, m in node.methods {
				emnames[m.name] = i
				emnames_ds[m.name] = true
				emnames_ds_info[m.name] = true
			}
			for i, f in node.fields {
				efnames[f.name] = i
				efnames_ds_info[f.name] = true
			}
			//
			for iface in all_ifaces {
				isym := c.table.sym(iface.typ)
				if isym.kind != .interface_ {
					c.error('interface `$node.name` tries to embed `$isym.name`, but `$isym.name` is not an interface, but `$isym.kind`',
						iface.pos)
					continue
				}
				isym_info := isym.info as ast.Interface
				for f in isym_info.fields {
					if !efnames_ds_info[f.name] {
						efnames_ds_info[f.name] = true
						decl_sym.info.fields << f
					}
				}
				for m in isym_info.methods {
					if !emnames_ds_info[m.name] {
						emnames_ds_info[m.name] = true
						decl_sym.info.methods << m.new_method_with_receiver_type(node.typ)
					}
				}
				for m in isym.methods {
					if !emnames_ds[m.name] {
						emnames_ds[m.name] = true
						decl_sym.methods << m.new_method_with_receiver_type(node.typ)
					}
				}
				if iface_decl := c.table.interfaces[iface.typ] {
					for f in iface_decl.fields {
						if f.name in efnames {
							// already existing method name, check for conflicts
							ifield := node.fields[efnames[f.name]]
							if field := c.table.find_field_with_embeds(isym, f.name) {
								if ifield.typ != field.typ {
									exp := c.table.type_to_str(ifield.typ)
									got := c.table.type_to_str(field.typ)
									c.error('embedded interface `$iface_decl.name` conflicts existing field: `$ifield.name`, expecting type: `$exp`, got type: `$got`',
										ifield.pos)
								}
							}
						} else {
							efnames[f.name] = node.fields.len
							node.fields << f
						}
					}
					for m in iface_decl.methods {
						if m.name in emnames {
							// already existing field name, check for conflicts
							imethod := node.methods[emnames[m.name]]
							if em_fn := decl_sym.find_method(imethod.name) {
								if m_fn := isym.find_method(m.name) {
									msg := c.table.is_same_method(m_fn, em_fn)
									if msg.len > 0 {
										em_sig := c.table.fn_signature(em_fn, skip_receiver: true)
										m_sig := c.table.fn_signature(m_fn, skip_receiver: true)
										c.error('embedded interface `$iface_decl.name` causes conflict: $msg, for interface method `$em_sig` vs `$m_sig`',
											imethod.pos)
									}
								}
							}
						} else {
							emnames[m.name] = node.methods.len
							mut new_method := m.new_method_with_receiver_type(node.typ)
							new_method.pos = iface.pos
							node.methods << new_method
						}
					}
				}
			}
		}
		for i, method in node.methods {
			if node.language == .v {
				c.check_valid_snake_case(method.name, 'method name', method.pos)
			}
			c.ensure_type_exists(method.return_type, method.return_type_pos) or { return }
			if is_js {
				mtyp := c.table.sym(method.return_type)
				if !mtyp.is_js_compatible() {
					c.error('method $method.name returns non JS type', method.pos)
				}
			}
			for j, param in method.params {
				if j == 0 && is_js {
					continue // no need to check first param
				}
				c.ensure_type_exists(param.typ, param.pos) or { return }
				if param.name in reserved_type_names {
					c.error('invalid use of reserved type `$param.name` as a parameter name',
						param.pos)
				}
				if is_js {
					ptyp := c.table.sym(param.typ)
					if !ptyp.is_js_compatible() && !(j == method.params.len - 1
						&& method.is_variadic) {
						c.error('method `$method.name` accepts non JS type as parameter',
							method.pos)
					}
				}
			}
			for field in node.fields {
				field_sym := c.table.sym(field.typ)
				if field.name == method.name && field_sym.kind == .function {
					c.error('type `$decl_sym.name` has both field and method named `$method.name`',
						method.pos)
				}
			}
			for j in 0 .. i {
				if method.name == node.methods[j].name {
					c.error('duplicate method name `$method.name`', method.pos)
				}
			}
		}
		for i, field in node.fields {
			if node.language == .v {
				c.check_valid_snake_case(field.name, 'field name', field.pos)
			}
			c.ensure_type_exists(field.typ, field.pos) or { return }
			if is_js {
				tsym := c.table.sym(field.typ)
				if !tsym.is_js_compatible() {
					c.error('field `$field.name` uses non JS type', field.pos)
				}
			}
			if field.typ == node.typ && node.language != .js {
				c.error('recursive interface fields are not allowed because they cannot be initialised',
					field.type_pos)
			}
			for j in 0 .. i {
				if field.name == node.fields[j].name {
					c.error('field name `$field.name` duplicate', field.pos)
				}
			}
		}
	}
}

fn (mut c Checker) resolve_generic_interface(typ ast.Type, interface_type ast.Type, pos token.Position) ast.Type {
	utyp := c.unwrap_generic(typ)
	typ_sym := c.table.sym(utyp)
	mut inter_sym := c.table.sym(interface_type)

	if mut inter_sym.info is ast.Interface {
		if inter_sym.info.is_generic {
			mut inferred_types := []ast.Type{}
			generic_names := inter_sym.info.generic_types.map(c.table.get_type_name(it))
			// inferring interface generic types
			for gt_name in generic_names {
				mut inferred_type := ast.void_type
				for ifield in inter_sym.info.fields {
					if ifield.typ.has_flag(.generic) && c.table.get_type_name(ifield.typ) == gt_name {
						if field := c.table.find_field_with_embeds(typ_sym, ifield.name) {
							inferred_type = field.typ
						}
					}
				}
				for imethod in inter_sym.info.methods {
					method := typ_sym.find_method(imethod.name) or {
						typ_sym.find_method_with_generic_parent(imethod.name) or { ast.Fn{} }
					}
					if imethod.return_type.has_flag(.generic) {
						imret_sym := c.table.sym(imethod.return_type)
						mret_sym := c.table.sym(method.return_type)
						if imret_sym.info is ast.MultiReturn && mret_sym.info is ast.MultiReturn {
							for i, mr_typ in imret_sym.info.types {
								if mr_typ.has_flag(.generic)
									&& c.table.get_type_name(mr_typ) == gt_name {
									inferred_type = mret_sym.info.types[i]
								}
							}
						} else if c.table.get_type_name(imethod.return_type) == gt_name {
							mut ret_typ := method.return_type
							if imethod.return_type.has_flag(.optional) {
								ret_typ = ret_typ.clear_flag(.optional)
							}
							inferred_type = ret_typ
						}
					}
					for i, iparam in imethod.params {
						param := method.params[i] or { ast.Param{} }
						if iparam.typ.has_flag(.generic)
							&& c.table.get_type_name(iparam.typ) == gt_name {
							inferred_type = param.typ
						}
					}
				}
				if inferred_type == ast.void_type {
					c.error('could not infer generic type `$gt_name` in interface', pos)
					return interface_type
				}
				inferred_types << inferred_type
			}
			// add concrete types to method
			for imethod in inter_sym.info.methods {
				if inferred_types !in c.table.fn_generic_types[imethod.name] {
					c.table.fn_generic_types[imethod.name] << inferred_types
				}
			}
			inter_sym.info.concrete_types = inferred_types
			return c.table.unwrap_generic_type(interface_type, generic_names, inter_sym.info.concrete_types)
		}
	}
	return interface_type
}
