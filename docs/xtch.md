# XTCH / XTH format

Cookbook writes the same container layout CrossPoint firmware reads.
Integers are little-endian. Page height must be a multiple of 8.

## XTCH container

Magic `XTCH` (`0x48435458`) at offset 0. Header is 56 bytes:

| Offset | Type | Field |
| --- | --- | --- |
| 0 | u32 | magic `XTCH` |
| 4 | u8 | version major |
| 5 | u8 | version minor |
| 6 | u16 | page count |
| 8 | u8 | read direction |
| 9 | u8 | has metadata |
| 10 | u8 | has thumbnails |
| 11 | u8 | has chapters |
| 12 | u32 | current page |
| 16 | u64 | title / metadata offset (always `0x38`) |
| 24 | u64 | page table offset |
| 32 | u64 | page data offset |
| 40 | u64 | thumbnail offset (0 if none) |
| 48 | u32 | chapter table offset (`0x138` if chapters exist, else 0) |
| 52 | u32 | padding |

Metadata (256 bytes) starts at `0x38`: title (128), author (64), publisher (32),
language (16), createTime (u32), coverPage (u16), chapterCount (u16), reserved (8).

Chapters, if any, start at `0x138`. Each chapter is 96 bytes: name (80 UTF-8
bytes, NUL-padded), startPage (u16, 1-based), endPage (u16), padding (12).

Page table entries are 16 bytes: offset (u64), size (u32), width (u16), height (u16).

## XTH page

Each page is an XTH blob: 22-byte header plus body.

| Offset | Type | Field |
| --- | --- | --- |
| 0 | u32 | magic `XTH\0` (`0x00485458`) |
| 4 | u16 | width |
| 6 | u16 | height |
| 8 | u8 | unused |
| 9 | u8 | compression (0 = raw, 1 = raw-DEFLATE, wbits = -15) |
| 10 | u32 | body size |
| 14 | u64 | unused |

The body is two bit-planes (plane 1 then plane 2), column-major, X reversed
(rightmost column first), 8 pixels per byte, MSB = top of the 8-pixel group.

Gray levels: `00` white, `10` light, `01` dark, `11` black.

Compression is optional and off by default. Only lazahata firmware is known
to open compressed pages.
