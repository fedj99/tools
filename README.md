# tools

A collection of single-purpose tools

## butcher.sh (a.k.a. "The Butcher")

This tool is intended to modify Ralf Hiptmair's awful videos to something slightly more bearable. To be more precise, the tool is capable of:

- Removing silent parts
- Apply audio filtering like pop and click removal, high- and low-pass filters
- Normalize volume in case the levels are off

### Usage

Upon first use, you might have to run the following command:

```bash
chmod +x ./butcher.sh
```

to make the file executable.

The tool can be operated in **interactive** or **CLI** mode. You can run interactive mode by typing

```bash
./butcher.sh -i
```

It will then start asking you questions about all necessary information.

In CLI mode, you just give all necessary parameters as options. Type `./butcher.sh --help` to see a list of available options and their description. Example:

```bash
./butcher.sh \
	--install-deps \
	--create-outdir \
	--options removesilence,audiofilters \
	./data/ \
	./out/
```

### Dependencies

butcher.sh has the following dependencies:

- ffmpeg
- ffpb
- python3
- pip3
- jumpcutter
- figlet

However, you do not need to install them manually, as the script will already do this for you automatically (simply answer `y` when prompted or `--install-deps` in CLI mode).