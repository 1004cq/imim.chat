import net from 'node:net';
import http from 'node:http';
import crypto from 'node:crypto';
const stats = { proxyConnections: 0, authenticatedConnections: 0, health: 0, signal: 0, proxyHealth: 0, proxySignal: 0, rejectedExternal: 0 };
const proxiedPorts = new Set();
const httpServer = http.createServer((req, res) => {
  if (!req.url.startsWith('/api/health')) { res.writeHead(404).end(); return; }
  stats.health++;
  if (proxiedPorts.has(req.socket.remotePort)) stats.proxyHealth++;
  if (req.url.includes('redirect=1')) { res.writeHead(302, {Location: 'https://example.invalid/'}).end(); return; }
  res.writeHead(200, {'Content-Type': 'application/json'}).end(JSON.stringify(stats));
});
httpServer.on('upgrade', (req, socket) => {
  if (req.url !== '/signal') { socket.destroy(); return; }
  stats.signal++;
  if (proxiedPorts.has(socket.remotePort)) stats.proxySignal++;
  const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  let buffer = Buffer.alloc(0);
  socket.on('error', () => {});
  socket.on('data', chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 2) {
      const opcode = buffer[0] & 15, masked = !!(buffer[1] & 128), length = buffer[1] & 127;
      if (length >= 126 || !masked) { socket.destroy(); return; }
      if (buffer.length < length + 6) return;
      const mask = buffer.subarray(2, 6), body = Buffer.from(buffer.subarray(6, 6 + length));
      for (let i = 0; i < body.length; i++) body[i] ^= mask[i % 4];
      buffer = buffer.subarray(length + 6);
      if (opcode === 8) { socket.end(Buffer.from([0x88, 0])); return; }
      if (opcode === 1) socket.write(Buffer.concat([Buffer.from([0x81, body.length]), body]));
      if (opcode === 9) socket.write(Buffer.concat([Buffer.from([0x8a, body.length]), body]));
    }
  });
});
await new Promise(resolve => httpServer.listen(0, '127.0.0.1', resolve));
const httpPort = httpServer.address().port;
const proxy = net.createServer(client => {
  stats.proxyConnections++;
  let buffer = Buffer.alloc(0), state = 'greeting', remote;
  client.on('error', () => { remote?.destroy(); });
  client.on('close', () => remote?.destroy());
  const parse = chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    if (state === 'greeting') {
      if (buffer.length < 2 || buffer.length < buffer[1] + 2) return;
      const methods = [...buffer.subarray(2, 2 + buffer[1])];
      if (buffer[0] !== 5) return client.destroy();
      const method = methods.includes(2) ? 2 : 0;
      buffer = buffer.subarray(2 + buffer[1]);
      client.write(Buffer.from([5, method])); state = method === 2 ? 'auth' : 'connect';
    }
    if (state === 'auth') {
      if (buffer.length < 2 || buffer.length < buffer[1] + 3) return;
      const ulen = buffer[1], plen = buffer[2 + ulen];
      if (buffer.length < ulen + plen + 3) return;
      const valid = buffer.subarray(2, 2 + ulen).toString() === 'fixture-user'
        && buffer.subarray(3 + ulen, 3 + ulen + plen).toString() === 'fixture-pass';
      if (!valid) { client.end(Buffer.from([1, 1])); return; }
      stats.authenticatedConnections++;
      buffer = buffer.subarray(3 + ulen + plen); client.write(Buffer.from([1, 0])); state = 'connect';
    }
    if (state !== 'connect' || buffer.length < 5) return;
    let host, offset;
    if (buffer[3] === 1) { host = [...buffer.subarray(4, 8)].join('.'); offset = 8; }
    else if (buffer[3] === 3) {
      if (buffer.length < 5 + buffer[4] + 2) return;
      host = buffer.subarray(5, 5 + buffer[4]).toString(); offset = 5 + buffer[4];
    } else { client.destroy(); return; }
    if (buffer.length < offset + 2) return;
    const port = buffer.readUInt16BE(offset);
    if (!['127.0.0.1', 'imim-proxy-fixture.invalid'].includes(host) || port !== httpPort) {
      stats.rejectedExternal++; client.end(Buffer.from([5, 2, 0, 1, 127, 0, 0, 1, 0, 0])); return;
    }
    const rest = buffer.subarray(offset + 2); state = 'tunnel';
    client.removeListener('data', parse); client.pause();
    remote = net.connect(port, '127.0.0.1', () => {
      proxiedPorts.add(remote.localPort);
      client.write(Buffer.from([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]));
      if (rest.length) remote.write(rest);
      remote.pipe(client); client.pipe(remote); client.resume();
    });
    remote.on('error', () => client.destroy());
    remote.on('close', () => client.destroy());
  };
  client.on('data', parse);
});
await new Promise(resolve => proxy.listen(0, '127.0.0.1', resolve));
const closed = net.createServer();
await new Promise(resolve => closed.listen(0, '127.0.0.1', resolve));
const closedPort = closed.address().port;
await new Promise(resolve => closed.close(resolve));
process.stdout.write(JSON.stringify({httpPort, proxyPort: proxy.address().port, closedPort}) + '\n');
process.on('SIGTERM', () => process.exit(0));
