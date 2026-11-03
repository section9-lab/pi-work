import { dirname, resolve } from "node:path";

const outputPath = resolve(process.argv[2] ?? "../build/pi-work-agent-host");
const photonWasmLookup = "require('path').join(__dirname, 'photon_rs_bg.wasm')";
const portablePhotonWasmLookup =
  "require('path').join(process.env.PI_WORK_AGENT_HOST_RESOURCE_DIR || require('path').dirname(process.argv[1] || process.execPath), 'photon_rs_bg.wasm')";

const result = await Bun.build({
  entrypoints: [resolve("src/main.ts")],
  target: "bun",
  minify: {
    whitespace: true,
    syntax: true,
    identifiers: false,
  },
  plugins: [{
    name: "portable-photon-wasm",
    setup(build) {
      build.onLoad({ filter: /photon-node\/photon_rs\.js$/ }, async ({ path }) => {
        const source = await Bun.file(path).text();
        if (!source.includes(photonWasmLookup)) {
          throw new Error(`Photon WASM lookup changed in ${path}`);
        }
        return {
          contents: source.replace(photonWasmLookup, portablePhotonWasmLookup),
          loader: "js",
        };
      });
    },
  }],
});

if (!result.success || result.outputs.length !== 1) {
  for (const log of result.logs) console.error(log);
  throw new Error("Agent Host bundle failed");
}

await Bun.write(outputPath, result.outputs[0]!);
console.log(`Bundled Agent Host at ${outputPath} (${result.outputs[0]!.size} bytes)`);
console.log(`Resources resolve beside ${dirname(outputPath)}`);
