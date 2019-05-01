# Set shell to bash to resolve symbolic links when looking up
# executables, to support user-account installation of stack.
SHELL=/bin/bash

%.so: %.c
	gcc -fPIC -shared $^ -o $@

update-%:
	./coddle tests/$*.cd > tests/$*.expected

run-%: tests/%.cd
	stack exec coddle $< > tests/$*.out
	diff -u tests/$*.expected tests/$*.out
	echo $* OK

all-tests: run-type-tests run-eval-tests

all-update-tests: update-type-tests update-eval-tests

clean:
	rm cbits/*.so
