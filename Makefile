KNIT_SOURCE = src/log.sh   \
              src/set.sh   \
              src/args.sh  \
              src/func.sh  \
              src/usage.sh \
              src/main.sh

KNIT_OUTPUT = knit.sh

all: knit.sh

knit.sh: $(KNIT_SOURCE)
	@echo "Concatenating files into $(KNIT_OUTPUT)..."
	cat $(KNIT_SOURCE) > $(KNIT_OUTPUT)
	@echo "Done. Created $(KNIT_OUTPUT)"

KNIT_TESTS := $(wildcard tests/test_*.sh)

.PHONY: check
check: $(KNIT_TESTS) knit.sh
	@echo "Running all Bats tests..."
	bats $(KNIT_TESTS)
	@echo "All tests completed."

.PHONY: clean
clean:
	@echo "Cleaning up..."
	rm -f $(KNIT_OUTPUT)
	@echo "Done."
