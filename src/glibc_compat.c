// Force memcpy to resolve against GLIBC_2.2.5 instead of GLIBC_2.14+.
// glibc 2.14 introduced a versioned memcpy (GLIBC_2.14) that changed
// overlap semantics. Binaries linked against it won't load on older
// systems. The .symver directive pins the symbol to the old version,
// making the resulting .so portable across glibc >= 2.2.5.
__asm__(".symver memcpy, memcpy@GLIBC_2.2.5");
