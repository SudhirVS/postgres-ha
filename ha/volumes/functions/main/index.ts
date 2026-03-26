import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

serve(async (req: Request) => {
  const url = new URL(req.url);
  const functionName = url.pathname.split("/")[1];

  if (!functionName) {
    return new Response(JSON.stringify({ error: "No function name provided" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ message: `Function ${functionName} not found` }), {
    status: 404,
    headers: { "Content-Type": "application/json" },
  });
});
