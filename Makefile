asmgrep: grep.s
	as --64 -o grep.o grep.s
	ld -o asmgrep grep.o

test: asmgrep
	./tests/run.sh

bench: asmgrep
	./tests/bench.sh

clean:
	rm -f grep.o asmgrep

.PHONY: test bench clean
