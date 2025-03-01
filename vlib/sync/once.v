module sync

import sync.atomic2

pub struct Once {
mut:
	m RwMutex
pub:
	count u64
}

// new_once return a new Once struct.
pub fn new_once() &Once {
	mut once := &Once{}
	once.m.init()
	return once
}

// do execute the function only once.
pub fn (mut o Once) do(f fn ()) {
	if atomic2.load_u64(&o.count) < 1 {
		o.do_slow(f)
	}
}

fn (mut o Once) do_slow(f fn ()) {
	o.m.@lock()
	if o.count < 1 {
		atomic2.store_u64(&o.count, 1)
		f()
	}
	o.m.unlock()
}
