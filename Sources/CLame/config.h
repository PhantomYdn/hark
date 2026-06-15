/* Minimal config.h for vendoring libmp3lame (encode-only) on macOS/clang,
 * replacing LAME's autoconf-generated config.h. Only the macros the encode
 * sources actually reference are set. SIMD (HAVE_XMMINTRIN_H), NASM, and the
 * mpglib decoder (HAVE_MPGLIB) are intentionally left undefined. */
#ifndef CLAME_CONFIG_H
#define CLAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_LIMITS_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_MEMORY_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_UNISTD_H 1
#define HAVE_CTYPE_H 1

/* Float types LAME would otherwise receive from autoconf. */
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;

#define PACKAGE "lame"
#define VERSION "3.100"

#endif /* CLAME_CONFIG_H */
