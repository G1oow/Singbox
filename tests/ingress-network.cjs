const fs = require("node:fs");
const path = require("node:path");
const net = require("node:net");
const http = require("node:http");
const dgram = require("node:dgram");
const { spawn } = require("node:child_process");
const { once } = require("node:events");
const assert = require("node:assert/strict");

const [mainFile, node4File, node6File, expected, topology = "separate"] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(mainFile, "utf8"));
const configFile = path.join(path.dirname(mainFile), "network-probe.json");
const http4 = http.createServer((_, response) => response.end("ipv4"));
const http6 = http.createServer((_, response) => response.end("ipv6"));
const dns = dgram.createSocket("udp4");
let child;
let childOutput = "";

async function listen(server, options) {
  server.listen(options);
  await once(server, "listening");
  return server.address().port;
}

// DNS 仅返回 loopback 地址，不访问公网。
dns.on("message", (query, remote) => {
  let end = 12;
  while (query[end]) end += query[end] + 1;
  end += 1;
  const type = query.readUInt16BE(end);
  const question = query.subarray(12, end + 4);
  const header = Buffer.from(query.subarray(0, 12));
  header.writeUInt16BE(0x8180, 2);
  header.writeUInt16BE(type === 1 || type === 28 ? 1 : 0, 6);
  header.writeUInt16BE(0, 8);
  header.writeUInt16BE(0, 10);
  const parts = [header, question];
  if (type === 1 || type === 28) {
    const address = type === 1 ? Buffer.from([127, 0, 0, 1]) : Buffer.alloc(16);
    if (type === 28) address[15] = 1;
    const answer = Buffer.alloc(12);
    answer.writeUInt16BE(0xc00c, 0);
    answer.writeUInt16BE(type, 2);
    answer.writeUInt16BE(1, 4);
    answer.writeUInt32BE(30, 6);
    answer.writeUInt16BE(address.length, 10);
    parts.push(answer, address);
  }
  dns.send(Buffer.concat(parts), remote.port, remote.address);
});

async function request(host, proxyPort, targetPort) {
  const socket = net.createConnection({ host, port: proxyPort });
  socket.setTimeout(5000, () => socket.destroy(new Error("SOCKS 请求超时")));
  try {
    await once(socket, "connect");
    const iterator = socket[Symbol.asyncIterator]();
    let buffer = Buffer.alloc(0);
    async function read(length) {
      while (buffer.length < length) {
        const next = await iterator.next();
        if (next.done) throw new Error("SOCKS 响应提前结束");
        buffer = Buffer.concat([buffer, next.value]);
      }
      const value = buffer.subarray(0, length);
      buffer = buffer.subarray(length);
      return value;
    }
    socket.write(Buffer.from([5, 1, 0]));
    assert.deepEqual(await read(2), Buffer.from([5, 0]));
    const domain = Buffer.from("ingress.test");
    const port = Buffer.alloc(2);
    port.writeUInt16BE(targetPort);
    socket.write(Buffer.concat([Buffer.from([5, 1, 0, 3, domain.length]), domain, port]));
    const response = await read(4);
    assert.equal(response[1], 0, `SOCKS 连接失败: ${response[1]}`);
    const addressLength = response[3] === 1 ? 4 : response[3] === 4 ? 16 : (await read(1))[0];
    await read(addressLength + 2);
    socket.write("GET / HTTP/1.1\r\nHost: ingress.test\r\nConnection: close\r\n\r\n");
    let body = buffer.toString();
    for (;;) {
      const next = await iterator.next();
      if (next.done) break;
      body += next.value.toString();
    }
    assert.ok(body.endsWith(expected), `${host} 入口未使用 ${expected} 出口: ${body}`);
  } finally {
    socket.destroy();
  }
}

async function closeServer(server) {
  if (server.listening) await new Promise((resolve) => server.close(resolve));
}

async function main() {
  const targetPort = await listen(http4, { host: "127.0.0.1", port: 0 });
  await listen(http6, { host: "::1", port: targetPort, ipv6Only: true });
  dns.bind(0, "127.0.0.1");
  await once(dns, "listening");
  const dnsPort = dns.address().port;
  const direct = config.outbounds.find((outbound) => outbound.tag === "direct");
  config.dns.servers = [
    direct.domain_resolver
      ? { type: "udp", tag: "egress-local", server: "127.0.0.1", server_port: dnsPort }
      : { address: `udp://127.0.0.1:${dnsPort}`, tag: "egress-local" },
  ];
  const probe = net.createServer();
  const proxyPort = await listen(probe, { host: "127.0.0.1", port: 0 });
  await closeServer(probe);
  const nodes = topology === "dual" ? [node4File] : [node4File, node6File];
  config.inbounds = nodes.map((file) => {
    const inbound = JSON.parse(fs.readFileSync(file, "utf8")).inbounds[0];
    // 测试仅改为随机端口和无认证，保留实际入口策略以及共用出口配置。
    return { ...inbound, listen_port: proxyPort, users: [] };
  });
  if (topology === "dual") {
    assert.equal(config.inbounds[0].listen, "::");
  } else {
    assert.equal(config.inbounds[0].listen, "127.0.0.1");
    assert.equal(config.inbounds[1].listen, "::1");
  }
  fs.writeFileSync(configFile, JSON.stringify(config));
  child = spawn(process.env.SING_BOX_BIN, ["run", "-c", configFile], {
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", (chunk) => { childOutput += chunk; });
  child.stderr.on("data", (chunk) => { childOutput += chunk; });
  let lastError;
  const deadline = Date.now() + 15000;
  for (let attempt = 0; attempt < 50 && Date.now() < deadline; attempt += 1) {
    if (child.exitCode !== null) throw new Error(`内核退出: ${childOutput}`);
    try {
      await request("127.0.0.1", proxyPort, targetPort);
      await request("::1", proxyPort, targetPort);
      console.log(`通过：真实 IPv4 / IPv6 同端口入口共存（${topology}），均使用 ${expected} 出口`);
      return;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error(`${lastError?.message}\n${childOutput}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
}).finally(async () => {
  if (child && child.exitCode === null) {
    const exited = once(child, "exit");
    child.kill();
    await exited;
  }
  await Promise.all([closeServer(http4), closeServer(http6)]);
  try { dns.close(); } catch {}
  if (fs.existsSync(configFile)) fs.unlinkSync(configFile);
});
