var b = haxe.io.Bytes.alloc(5);
b.set(0, 12);
b.get(0) == 12;
b.get(1) == 0;
b.get(2) == 0;
b.get(3) == 0;
b.get(4) == 0;
var b2 = b.sub(0, 3);
b2.length == 3;
b2.get(0) == 12;
b2.get(1) == 0;
b2.get(2) == 0;
var b3 = haxe.io.Bytes.alloc(3);
b3.blit(1, b2, 0, 2);
b3.get(0) == 0;
b3.get(1) == 12;
b3.get(2) == 0;