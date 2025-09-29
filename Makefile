.PHONY: test coverage

test: 
	dart test .

coverage:
	dart run coverage:test_with_coverage 
	echo 'Coverage result: \n'
	lcov --list coverage/lcov.info

coverage-html:
	dart run coverage:test_with_coverage
	genhtml coverage/lcov.info -o coverage/html
	open coverage/html/index.html
