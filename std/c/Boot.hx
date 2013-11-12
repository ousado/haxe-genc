package c;

import c.Exception;
import c.TypeReference;
import c.Types;
import c.NInt;
import String;
import c.Closure;
import c.VTable;

@:headerCode('

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _MSC_VER
	#define ALLOCA(n) alloca(n)
#else
	#define ALLOCA(n) _alloca(n)
#endif

#define hxc_add(a,b) (a+b)
#define hxc_sub(a,b) (a-b)
#define hxc_mul(a,b) (a*b)
#define hxc_div(a,b) (a/b)
#define hxc_shl(a,b) (a<<b)
#define hxc_shr(a,b) (a>>b)
#define hxc_and(a,b) (a&b)
#define hxc_or(a,b) (a|b)
#define hxc_xor(a,b) (a^b)
#define hxc_land(a,b) (a && b)
#define hxc_lor(a,b) (a || b)
#define hxc_gt(a,b) (a>b)
#define hxc_lt(a,b) (a<b)
#define hxc_gte(a,b) (a>=b)
#define hxc_lte(a,b) (a<=b)

typedef unsigned char hx_uchar;
typedef char hx_char;
typedef unsigned int hx_uint;
typedef unsigned char hx_uint8;
typedef char hx_int8;
typedef unsigned long hx_uint32;
typedef long hx_int32;
typedef unsigned long long hx_uint64;
typedef long long hx_int64;
typedef int Date;
')
@:keep
@:native('hxc')
class Boot {
	static public var argc:Int;
	static public var argv:Pointer<Pointer<Char>>;
	static public var typeReferences:Array<c.TypeReference<Dynamic>>;

	static public function registerType(typeref:TypeReference<Dynamic>) {
		typeReferences.push(typeref);
	}

	@:plain static public function main(argc:Int, argv:Pointer<Pointer<Char>>):Int {
		Boot.argc = argc;
		Boot.argv = argv;
		typeReferences = [];
		c.Init._hx_init();
		try {
			c.Lib.callMain();
			return 0;
		} catch(e:Dynamic) {
			trace(Std.string(e));
			return 1;
		}
	}
}