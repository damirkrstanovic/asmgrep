# Builds the three implementations of asmgrep into bin/.
#   make        -> asm (default)
#   make all    -> asm + C
#   make c      -> C version (gcc/clang)
#   make zig    -> Zig version (needs `zig`)
BIN := bin

.DEFAULT_GOAL := asm
all: asm c

asm: $(BIN)/asmgrep
$(BIN)/asmgrep: asm/grep.s | $(BIN)
	as --64 -o $(BIN)/grep.o $<
	ld -o $@ $(BIN)/grep.o

c: $(BIN)/cgrep
$(BIN)/cgrep: c/grep.c | $(BIN)
	$(CC) -O2 -pthread -march=native -o $@ $<

zig: $(BIN)/zgrep
$(BIN)/zgrep: zig/grep.zig | $(BIN)
	zig build-exe -O ReleaseFast -femit-bin=$@ $<

# idiomatic / stdlib versions (single-threaded, high-level stdlib)
cstd: $(BIN)/cgrep_std
$(BIN)/cgrep_std: c/grep_std.c | $(BIN)
	$(CC) -O2 -o $@ $<

zigstd: $(BIN)/zgrep_std
$(BIN)/zgrep_std: zig/grep_std.zig | $(BIN)
	zig build-exe -O ReleaseFast -femit-bin=$@ $<

go: $(BIN)/gogrep
$(BIN)/gogrep: go/grep.go go/go.mod | $(BIN)
	cd go && go build -o ../$(BIN)/gogrep .

$(BIN):
	mkdir -p $(BIN)

test: asm
	./tests/run.sh
bench: all
	./tests/bench.sh
compare: all
	./tests/compare.sh

clean:
	rm -rf $(BIN)

.PHONY: all asm c zig test bench compare clean
