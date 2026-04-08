// Pin memcpy to GLIBC_2.2.5 for portability across older glibc.
// This header is force-included into every C/C++ TU via -include.
#ifdef __linux__
__asm__(".symver memcpy, memcpy@GLIBC_2.2.5");
#endif