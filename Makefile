.PHONY: build app test clean run icons

icons:
	./scripts/build-icons.sh

build:
	swift build

app:
	./scripts/build-app.sh

test:
	swift test

run: app
	open build/Kindling.app

clean:
	rm -rf .build build
