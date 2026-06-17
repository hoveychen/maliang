import { buildServer } from './server.ts';

const port = Number(process.env.PORT ?? 8080);
const app = await buildServer();
await app.listen({ port, host: '0.0.0.0' });
app.log.info(`maliang server listening on :${port}`);
