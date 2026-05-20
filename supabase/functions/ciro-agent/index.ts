import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.46.1";

const PRIMARY_MODEL_API_URL = "https://api.groq.com/openai/v1/chat/completions";
const PRIMARY_MODEL = "llama-3.3-70b-versatile";
const PRIMARY_MODEL_KEY_ENV = "GROQ_API_KEY";
const PRIMARY_MODEL_TIMEOUT_MS = 45_000;
const FALLBACK_MODEL_API_URL = "https://inference.do-ai.run/v1/chat/completions";
const FALLBACK_MODEL = "kimi-k2.6";
const FALLBACK_MODEL_KEY_ENV = "MODEL_ACCESS_KEY";
const FALLBACK_MODEL_TIMEOUT_MS = 30_000;
const STALE_RUN_MS = 120_000;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Json = Record<string, unknown>;

type AgentContext = {
  admin: SupabaseClient;
  userId: string;
  runId: string;
  logId?: string;
};

type ChatMessage = {
  role: "system" | "user" | "assistant" | "tool";
  content?: string | null;
  tool_call_id?: string;
  tool_calls?: unknown[];
};

type ToolCall = {
  id: string;
  type: "function";
  function: {
    name: string;
    arguments: string;
  };
};

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function optionalEnv(name: string): string | undefined {
  return Deno.env.get(name) || undefined;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function queueBackgroundTask(task: Promise<unknown>) {
  const runtime = (globalThis as unknown as { EdgeRuntime?: { waitUntil?: (promise: Promise<unknown>) => void } }).EdgeRuntime;
  const guardedTask = task.catch((error) => {
    console.error("Background agent task failed", error);
  });

  if (runtime?.waitUntil) {
    runtime.waitUntil(guardedTask);
  } else {
    guardedTask.catch((error) => console.error("Unhandled background agent task failure", error));
  }
}

function parseJson(text: string): Json {
  if (!text || text.trim().length === 0) {
    return {};
  }
  
  // Remove markdown code blocks and Groq's <think> tags
  let trimmed = text.trim()
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```$/i, "")
    .replace(/<think>[\s\S]*?<\/think>/gi, "")
    .trim();
  
  // Try direct parse first
  try {
    return JSON.parse(trimmed);
  } catch {
    // Extract JSON object from mixed content
    const start = trimmed.indexOf("{");
    const end = trimmed.lastIndexOf("}");
    if (start >= 0 && end > start) {
      const jsonStr = trimmed.slice(start, end + 1);
      try {
        return JSON.parse(jsonStr);
      } catch (e) {
        // Last resort: try to fix common JSON issues
        const fixed = jsonStr
          .replace(/,(\s*[}\]])/g, "$1") // Remove trailing commas
          .replace(/([{,]\s*)(\w+):/g, '$1"$2":') // Quote unquoted keys
          .replace(/:\s*'([^']*)'/g, ': "$1"'); // Replace single quotes with double
        try {
          return JSON.parse(fixed);
        } catch {
          throw new Error(`Model did not return valid JSON: ${trimmed.slice(0, 300)}`);
        }
      }
    }
    throw new Error(`Model did not return valid JSON: ${trimmed.slice(0, 300)}`);
  }
}

function asObject(value: unknown): Json {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Json : {};
}

function asArray<T = unknown>(value: unknown): T[] {
  return Array.isArray(value) ? value as T[] : [];
}

function numberOrUndefined(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function stringOrDefault(value: unknown, fallback: string): string {
  return typeof value === "string" && value.trim().length > 0 ? value : fallback;
}

function sanitizedAlias(value: string): string {
  return value
    .replace(/\s+/g, " ")
    .trim();
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function isOlderThan(value: unknown, ageMs: number): boolean {
  if (typeof value !== "string") return false;
  const time = Date.parse(value);
  return Number.isFinite(time) && Date.now() - time > ageMs;
}

function haversineMeters(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const r = 6371000;
  const toRad = (degrees: number) => degrees * Math.PI / 180;
  const dLat = toRad(bLat - aLat);
  const dLng = toRad(bLng - aLng);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(aLat)) * Math.cos(toRad(bLat)) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(h));
}

async function getAuthedUser(req: Request): Promise<{ id: string; email?: string }> {
  const url = requireEnv("SUPABASE_URL");
  const anon = requireEnv("SUPABASE_ANON_KEY");
  const authorization = req.headers.get("Authorization");
  if (!authorization) {
    throw new HttpError(401, "Missing Authorization header");
  }

  const userClient = createClient(url, anon, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data, error } = await userClient.auth.getUser();
  if (error || !data.user) {
    throw new HttpError(401, error?.message ?? "Invalid Supabase session");
  }
  return { id: data.user.id, email: data.user.email ?? undefined };
}

function adminClient(): SupabaseClient {
  return createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false },
  });
}

class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

type ModelProvider = {
  name: string;
  apiUrl: string;
  model: string;
  apiKeyEnv: string;
  timeoutMs: number;
};

function isModelTimeout(error: unknown): boolean {
  const message = error instanceof Error ? `${error.name} ${error.message}` : String(error);
  return /model_timeout|timeout|abort/i.test(message);
}

async function chatCompletionWithProvider(provider: ModelProvider, messages: ChatMessage[], tools: unknown[]) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort("model_timeout"), provider.timeoutMs);
  
  const requestBody: Record<string, unknown> = {
    model: provider.model,
    messages,
    temperature: 0.15,
  };
  
  // Only add tools if provided
  if (tools && tools.length > 0) {
    requestBody.tools = tools;
    requestBody.tool_choice = "auto";
  }
  
  const response = await fetch(provider.apiUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${requireEnv(provider.apiKeyEnv)}`,
      "Content-Type": "application/json",
    },
    signal: controller.signal,
    body: JSON.stringify(requestBody),
  }).finally(() => clearTimeout(timeout));

  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(`${provider.name} API error ${response.status}: ${JSON.stringify(payload).slice(0, 700)}`);
  }
  return payload?.choices?.[0]?.message;
}

async function chatCompletion(messages: ChatMessage[], tools: unknown[]) {
  const primary: ModelProvider = {
    name: "Groq Llama 3.3 70B",
    apiUrl: PRIMARY_MODEL_API_URL,
    model: PRIMARY_MODEL,
    apiKeyEnv: PRIMARY_MODEL_KEY_ENV,
    timeoutMs: PRIMARY_MODEL_TIMEOUT_MS,
  };
  const fallback: ModelProvider = {
    name: "DigitalOcean Kimi",
    apiUrl: FALLBACK_MODEL_API_URL,
    model: FALLBACK_MODEL,
    apiKeyEnv: FALLBACK_MODEL_KEY_ENV,
    timeoutMs: FALLBACK_MODEL_TIMEOUT_MS,
  };

  try {
    return await chatCompletionWithProvider(primary, messages, tools);
  } catch (error) {
    if (!isModelTimeout(error)) {
      throw error;
    }
    if (!optionalEnv(fallback.apiKeyEnv)) {
      throw new Error(`Primary model timed out and ${fallback.apiKeyEnv} is not configured for fallback recovery: ${error instanceof Error ? error.message : String(error)}`);
    }
    try {
      return await chatCompletionWithProvider(fallback, messages, tools);
    } catch (fallbackError) {
      throw new Error(`Primary model timed out and Kimi fallback failed: ${fallbackError instanceof Error ? fallbackError.message : String(fallbackError)}`);
    }
  }
}

const toolDefinitions = [
  {
    type: "function",
    function: {
      name: "geocode_locations",
      description: "Resolve one or more noisy place names, Urdu/Roman Urdu aliases, landmarks, or addresses to coordinates using Google Geocoding.",
      parameters: {
        type: "object",
        properties: {
          locations: { type: "array", items: { type: "string" } },
          region_bias: { type: "string", description: "Optional country or city bias, such as PK or Lahore, PK." },
        },
        required: ["locations"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "fetch_weather",
      description: "Fetch current real weather context for a coordinate.",
      parameters: {
        type: "object",
        properties: {
          latitude: { type: "number" },
          longitude: { type: "number" },
        },
        required: ["latitude", "longitude"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "search_latest_web_news",
      description: "Search the latest web/news context with Exa AI for corroboration and situational evidence.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string" },
          location: { type: "string" },
          category: { type: "string", enum: ["news", "web"] },
          hours_back: { type: "number" },
        },
        required: ["query"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "compute_route_alternatives",
      description: "Compute Google Maps Routes alternatives around a crisis area. This does not modify real Google traffic.",
      parameters: {
        type: "object",
        properties: {
          origin: {
            type: "object",
            properties: { latitude: { type: "number" }, longitude: { type: "number" } },
            required: ["latitude", "longitude"],
          },
          destination: {
            type: "object",
            properties: { latitude: { type: "number" }, longitude: { type: "number" } },
            required: ["latitude", "longitude"],
          },
          incident_id: { type: ["string", "null"], description: "Optional UUID to associate routes with an incident" },
        },
        required: ["origin", "destination"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "upsert_incident",
      description: "Create or update an incident in Supabase from clustered live signals and evidence. Omit incident_id to create a new incident, or provide it to update an existing one.",
      parameters: {
        type: "object",
        properties: {
          incident_id: { type: ["string", "null"], description: "UUID of existing incident to update, or omit/null to create new" },
          title: { type: "string" },
          description: { type: "string" },
          category: { type: "string" },
          status: { type: "string" },
          severity: { type: "number" },
          confidence: { type: "number" },
          centroid_lat: { type: "number" },
          centroid_lng: { type: "number" },
          summary: { type: "object" },
          evidence_summary: { type: "object" },
        },
        required: ["title", "category", "severity", "confidence"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "create_response_action",
      description: "Create a coordinated simulated response action for an incident.",
      parameters: {
        type: "object",
        properties: {
          incident_id: { type: "string" },
          action_type: { type: "string", enum: ["reroute", "alert", "ticket", "assign_resource", "monitor", "field_check", "public_guidance"] },
          title: { type: "string" },
          description: { type: "string" },
          priority: { type: "number" },
          payload: { type: "object" },
        },
        required: ["incident_id", "action_type", "title", "priority"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "run_simulation",
      description: "Execute app-owned mock response execution in Supabase: route layer changes, ranked mock provider booking, resource assignments, and before-vs-after metrics only.",
      parameters: {
        type: "object",
        properties: {
          incident_id: { type: "string" },
          scenario: { type: "string" },
          actions: { type: "array", items: { type: "object" } },
        },
        required: ["incident_id", "scenario"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "create_mock_emergency_ticket",
      description: "Create a clearly marked mock emergency ticket. This never contacts real emergency services.",
      parameters: {
        type: "object",
        properties: {
          incident_id: { type: "string" },
          simulation_run_id: { type: ["string", "null"], description: "Optional simulation run UUID" },
          ticket_type: { type: "string" },
          priority: { type: "number" },
          summary: { type: "string" },
          details: { type: "string" },
          payload: { type: "object" },
        },
        required: ["incident_id", "summary", "priority"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "create_mock_alert",
      description: "Create an in-app/SMS/email/push mock alert in Supabase. This is simulated only.",
      parameters: {
        type: "object",
        properties: {
          incident_id: { type: "string" },
          simulation_run_id: { type: ["string", "null"], description: "Optional simulation run UUID" },
          audience: { type: "string" },
          channel: { type: "string", enum: ["in_app", "sms_mock", "email_mock", "push_mock", "radio_mock"] },
          title: { type: "string" },
          body: { type: "string" },
          payload: { type: "object" },
        },
        required: ["incident_id", "audience", "channel", "title", "body"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "write_agent_log",
      description: "Write an explicit agent trace log into Supabase. Agents must never silently skip logging.",
      parameters: {
        type: "object",
        properties: {
          agent_name: { type: "string" },
          step: { type: "string" },
          status: { type: "string", enum: ["running", "completed", "failed", "skipped"] },
          message: { type: "string" },
          payload: { type: "object" },
        },
        required: ["agent_name", "step", "status", "message"],
      },
    },
  },
];

function selectTools(names: string[]) {
  return toolDefinitions.filter((tool) => names.includes(tool.function.name));
}

async function runAgent(
  ctx: AgentContext,
  agentName: string,
  step: string,
  systemPrompt: string,
  input: Json,
  toolNames: string[],
): Promise<Json> {
  const startedAt = new Date().toISOString();
  const { data: log, error: logError } = await ctx.admin
    .from("agent_logs")
    .insert({
      agent_run_id: ctx.runId,
      agent_name: agentName,
      step,
      status: "running",
      message: "Agent started",
      input_payload: input,
      started_at: startedAt,
    })
    .select("id")
    .single();

  if (logError || !log) {
    throw new Error(`Failed to create agent log for ${agentName}: ${logError?.message}`);
  }

  const logId = log.id as string;
  const localCtx = { ...ctx, logId };

  try {
    const messages: ChatMessage[] = [
      {
        role: "system",
        content: `${systemPrompt}

Return one strict JSON object only. Do not use markdown, code blocks, or <think> tags. Output only raw JSON.
Every key must be useful to downstream automation.
All emergency tickets and alerts are mock/simulated; never imply real emergency services were contacted.`,
      },
      { role: "user", content: JSON.stringify(input) },
    ];

    let finalMessage = await chatCompletion(messages, selectTools(toolNames));
    for (let round = 0; round < 3 && Array.isArray(finalMessage?.tool_calls) && finalMessage.tool_calls.length > 0; round++) {
      const toolCalls = finalMessage.tool_calls as ToolCall[];
      messages.push({
        role: "assistant",
        content: finalMessage.content ?? null,
        tool_calls: toolCalls,
      });

      for (const call of toolCalls) {
        const args = parseToolArguments(call.function.arguments);
        const result = await executeTool(localCtx, call.function.name, args);
        messages.push({
          role: "tool",
          tool_call_id: call.id,
          content: JSON.stringify(result),
        });
      }

      finalMessage = await chatCompletion(messages, selectTools(toolNames));
    }

    const output = parseJson(finalMessage?.content ?? "{}");
    await ctx.admin
      .from("agent_logs")
      .update({
        status: "completed",
        message: String(output.summary ?? output.rationale ?? `${agentName} completed`),
        output_payload: output,
        confidence: numberOrUndefined(output.confidence),
        completed_at: new Date().toISOString(),
      })
      .eq("id", logId);
    return output;
  } catch (error) {
    await ctx.admin
      .from("agent_logs")
      .update({
        status: "failed",
        message: `${agentName} failed`,
        error: error instanceof Error ? error.message : String(error),
        completed_at: new Date().toISOString(),
      })
      .eq("id", logId);
    throw error;
  }
}

function parseToolArguments(raw: string): Json {
  if (!raw || raw.trim().length === 0) return {};
  try {
    return JSON.parse(raw);
  } catch {
    return parseJson(raw);
  }
}

async function executeTool(ctx: AgentContext, name: string, args: Json): Promise<Json> {
  const started = performance.now();
  const { data: call, error: callError } = await ctx.admin
    .from("tool_calls")
    .insert({
      agent_run_id: ctx.runId,
      agent_log_id: ctx.logId,
      tool_name: name,
      status: "running",
      arguments: args,
    })
    .select("id")
    .single();

  if (callError || !call) {
    throw new Error(`Failed to log tool call ${name}: ${callError?.message}`);
  }

  try {
    const result = await toolHandlers[name](ctx, args);
    await ctx.admin
      .from("tool_calls")
      .update({
        status: "completed",
        result,
        latency_ms: Math.round(performance.now() - started),
      })
      .eq("id", call.id);
    return result;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await ctx.admin
      .from("tool_calls")
      .update({
        status: "failed",
        error: message,
        latency_ms: Math.round(performance.now() - started),
      })
      .eq("id", call.id);
    throw error;
  }
}

const toolHandlers: Record<string, (ctx: AgentContext, args: Json) => Promise<Json>> = {
  geocode_locations: async (_ctx, args) => {
    const key = requireEnv("GOOGLE_MAPS_API_KEY");
    const locations = asArray<string>(args.locations).filter(Boolean);
    const regionBias = typeof args.region_bias === "string" ? args.region_bias : undefined;
    const results = [];

    for (const location of locations.slice(0, 5)) {
      const url = new URL("https://maps.googleapis.com/maps/api/geocode/json");
      url.searchParams.set("address", location);
      if (regionBias) url.searchParams.set("region", regionBias);
      url.searchParams.set("key", key);
      const response = await fetch(url);
      const payload = await response.json();
      if (!response.ok || payload.status === "REQUEST_DENIED") {
        throw new Error(`Google Geocoding failed for ${location}: ${JSON.stringify(payload).slice(0, 400)}`);
      }
      results.push({
        query: location,
        status: payload.status,
        candidates: asArray<Json>(payload.results).slice(0, 3).map((raw) => {
          const item = asObject(raw);
          const geometry = asObject(item.geometry);
          const point = asObject(geometry.location);
          return {
            formatted_address: item.formatted_address,
            place_id: item.place_id,
            latitude: point.lat,
            longitude: point.lng,
            location_type: geometry.location_type,
            types: item.types,
          };
        }),
      });
    }
    return { results };
  },

  fetch_weather: async (_ctx, args) => {
    const key = requireEnv("OPENWEATHER_API_KEY");
    const lat = numberOrUndefined(args.latitude);
    const lon = numberOrUndefined(args.longitude);
    if (lat === undefined || lon === undefined) throw new Error("fetch_weather requires latitude and longitude");
    const url = new URL("https://api.openweathermap.org/data/2.5/weather");
    url.searchParams.set("lat", String(lat));
    url.searchParams.set("lon", String(lon));
    url.searchParams.set("appid", key);
    url.searchParams.set("units", "metric");
    const response = await fetch(url);
    const payload = await response.json();
    if (!response.ok) throw new Error(`OpenWeather failed: ${JSON.stringify(payload).slice(0, 400)}`);
    return {
      provider: "openweather",
      observed_at: new Date().toISOString(),
      location: { latitude: lat, longitude: lon, name: payload.name },
      condition: payload.weather?.[0]?.main,
      description: payload.weather?.[0]?.description,
      temperature_c: payload.main?.temp,
      feels_like_c: payload.main?.feels_like,
      humidity: payload.main?.humidity,
      wind_mps: payload.wind?.speed,
      rain_1h_mm: payload.rain?.["1h"] ?? 0,
      raw: payload,
    };
  },

  search_latest_web_news: async (_ctx, args) => {
    const key = requireEnv("EXA_API_KEY");
    const query = String(args.query ?? "").trim();
    if (!query) throw new Error("search_latest_web_news requires query");
    const hoursBack = typeof args.hours_back === "number" ? args.hours_back : 72;
    const start = new Date(Date.now() - hoursBack * 60 * 60 * 1000).toISOString();
    const response = await fetch("https://api.exa.ai/search", {
      method: "POST",
      headers: { "x-api-key": key, "Content-Type": "application/json" },
      body: JSON.stringify({
        query: [query, args.location].filter(Boolean).join(" "),
        type: "auto",
        category: args.category === "web" ? undefined : "news",
        numResults: 6,
        startPublishedDate: start,
        contents: { highlights: true, summary: true },
      }),
    });
    const payload = await response.json();
    if (!response.ok) throw new Error(`Exa search failed: ${JSON.stringify(payload).slice(0, 500)}`);
    return {
      provider: "exa",
      query,
      start_published_date: start,
      results: asArray<Json>(payload.results).map((raw) => {
        const item = asObject(raw);
        return {
          title: item.title,
          url: item.url,
          publishedDate: item.publishedDate,
          author: item.author,
          highlights: item.highlights,
          summary: item.summary,
        };
      }),
    };
  },

  compute_route_alternatives: async (ctx, args) => {
    const key = requireEnv("GOOGLE_MAPS_API_KEY");
    const origin = asObject(args.origin);
    const destination = asObject(args.destination);
    const originLat = numberOrUndefined(origin.latitude);
    const originLng = numberOrUndefined(origin.longitude);
    const destLat = numberOrUndefined(destination.latitude);
    const destLng = numberOrUndefined(destination.longitude);
    if ([originLat, originLng, destLat, destLng].some((value) => value === undefined)) {
      throw new Error("compute_route_alternatives requires origin and destination coordinates");
    }

    const response = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": key,
        "X-Goog-FieldMask": "routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,routes.description,routes.routeLabels",
      },
      body: JSON.stringify({
        origin: { location: { latLng: { latitude: originLat, longitude: originLng } } },
        destination: { location: { latLng: { latitude: destLat, longitude: destLng } } },
        travelMode: "DRIVE",
        routingPreference: "TRAFFIC_AWARE_OPTIMAL",
        computeAlternativeRoutes: true,
      }),
    });
    const payload = await response.json();
    if (!response.ok) throw new Error(`Google Routes failed: ${JSON.stringify(payload).slice(0, 500)}`);

    const routes = asArray<Json>(payload.routes).slice(0, 3).map((raw, index) => {
      const route = asObject(raw);
      const polyline = asObject(route.polyline);
      return {
        rank: index + 1,
        eta_seconds: parseDurationSeconds(route.duration),
        distance_meters: route.distanceMeters,
        polyline: polyline.encodedPolyline,
        description: route.description,
        labels: route.routeLabels,
      };
    });

    const incidentId = typeof args.incident_id === "string" ? args.incident_id : undefined;
    if (incidentId) {
      for (const route of routes) {
        await ctx.admin.from("route_options").insert({
          incident_id: incidentId,
          origin,
          destination,
          status: route.rank === 1 ? "recommended" : "candidate",
          eta_seconds: route.eta_seconds,
          distance_meters: route.distance_meters,
          polyline: route.polyline,
          payload: { provider_response: route, simulation_notice: "candidate route only; real Google traffic is not modified" },
        });
      }
    }

    return { provider: "google_routes", routes, simulation_notice: "route alternatives are app-owned recommendations only" };
  },

  upsert_incident: async (ctx, args) => {
    return await upsertIncident(ctx.admin, args);
  },

  create_response_action: async (ctx, args) => {
    const { data, error } = await ctx.admin
      .from("response_actions")
      .insert({
        incident_id: String(args.incident_id),
        action_type: String(args.action_type),
        title: String(args.title),
        description: typeof args.description === "string" ? args.description : null,
        priority: clamp(Math.round(Number(args.priority ?? 3)), 1, 5),
        status: "planned",
        payload: { ...asObject(args.payload), simulated_only: true },
        created_by: ctx.userId,
      })
      .select("*")
      .single();
    if (error) throw new Error(`Failed to create response action: ${error.message}`);
    return data as Json;
  },

  run_simulation: async (ctx, args) => {
    return await createSimulation(ctx, String(args.incident_id), String(args.scenario ?? "safe_response_execution"), asArray(args.actions));
  },

  create_mock_emergency_ticket: async (ctx, args) => {
    const now = new Date();
    const { data, error } = await ctx.admin
      .from("emergency_tickets")
      .insert({
        incident_id: String(args.incident_id),
        simulation_run_id: typeof args.simulation_run_id === "string" ? args.simulation_run_id : null,
        external_ref: `MOCK-${now.toISOString().slice(0, 10).replaceAll("-", "")}-${crypto.randomUUID().slice(0, 8).toUpperCase()}`,
        ticket_type: String(args.ticket_type ?? "mock_dispatch"),
        priority: clamp(Math.round(Number(args.priority ?? 3)), 1, 5),
        status: "created_mock",
        summary: String(args.summary),
        details: typeof args.details === "string" ? args.details : null,
        payload: { ...asObject(args.payload), simulated_only: true, real_services_contacted: false },
      })
      .select("*")
      .single();
    if (error) throw new Error(`Failed to create mock emergency ticket: ${error.message}`);
    return data as Json;
  },

  create_mock_alert: async (ctx, args) => {
    const { data, error } = await ctx.admin
      .from("mock_alerts")
      .insert({
        incident_id: String(args.incident_id),
        simulation_run_id: typeof args.simulation_run_id === "string" ? args.simulation_run_id : null,
        audience: String(args.audience),
        channel: String(args.channel ?? "in_app"),
        title: String(args.title),
        body: String(args.body),
        status: "sent_mock",
        sent_at: new Date().toISOString(),
        payload: { ...asObject(args.payload), simulated_only: true, real_public_alert_sent: false },
      })
      .select("*")
      .single();
    if (error) throw new Error(`Failed to create mock alert: ${error.message}`);
    return data as Json;
  },

  write_agent_log: async (ctx, args) => {
    const { data, error } = await ctx.admin
      .from("agent_logs")
      .insert({
        agent_run_id: ctx.runId,
        agent_name: String(args.agent_name),
        step: String(args.step),
        status: String(args.status),
        message: String(args.message),
        input_payload: {},
        output_payload: asObject(args.payload),
        completed_at: new Date().toISOString(),
      })
      .select("*")
      .single();
    if (error) throw new Error(`Failed to write agent log: ${error.message}`);
    return data as Json;
  },
};

function parseDurationSeconds(duration: unknown): number | undefined {
  if (typeof duration !== "string") return undefined;
  const match = duration.match(/^(\d+(?:\.\d+)?)s$/);
  return match ? Math.round(Number(match[1])) : undefined;
}

async function upsertIncident(admin: SupabaseClient, args: Json): Promise<Json> {
  const payload = {
    title: String(args.title ?? "Unclassified incident"),
    description: typeof args.description === "string" ? args.description : null,
    category: String(args.category ?? "unknown"),
    status: String(args.status ?? "active"),
    severity: clamp(Math.round(Number(args.severity ?? 1)), 1, 5),
    confidence: clamp(Number(args.confidence ?? 0), 0, 1),
    centroid_lat: numberOrUndefined(args.centroid_lat) ?? null,
    centroid_lng: numberOrUndefined(args.centroid_lng) ?? null,
    last_signal_at: new Date().toISOString(),
    summary: asObject(args.summary),
    evidence_summary: asObject(args.evidence_summary),
  };

  const incidentId = typeof args.incident_id === "string" ? args.incident_id.trim() : "";
  const hasIncidentId = incidentId.length > 0 && incidentId !== "null" && incidentId !== "undefined";

  if (hasIncidentId) {
    const { data, error } = await admin
      .from("incidents")
      .update(payload)
      .eq("id", incidentId)
      .select("*")
      .maybeSingle();
    if (error) throw new Error(`Failed to update incident: ${error.message}`);
    if (data) return data as Json;
  }

  const { data, error } = await admin.from("incidents").insert(payload).select("*").single();
  if (error) throw new Error(`Failed to create incident: ${error.message}`);
  return data as Json;
}

const PROVIDER_BOOKING_SEED = "crisisx_provider_booking_v1";

function preferredResourceTypes(category: string): string[] {
  const normalized = category.toLowerCase();
  if (normalized.includes("fire")) return ["fire_unit_mock", "medical_team_mock", "police_unit_mock"];
  if (normalized.includes("medical")) return ["ambulance_mock", "medical_team_mock", "relief_team_mock"];
  if (normalized.includes("traffic") || normalized.includes("infrastructure")) return ["road_crew_mock", "police_unit_mock", "ambulance_mock"];
  if (normalized.includes("violence")) return ["police_unit_mock", "ambulance_mock", "relief_team_mock"];
  if (normalized.includes("flood") || normalized.includes("weather") || normalized.includes("environment")) {
    return ["relief_team_mock", "road_crew_mock", "medical_team_mock"];
  }
  return ["relief_team_mock", "ambulance_mock", "road_crew_mock"];
}

function providerTemplatesForIncident(incident: Json): Json[] {
  const category = stringOrDefault(incident.category, "unknown").toLowerCase();
  const incidentId = String(incident.id);
  const lat = Number.isFinite(Number(incident.centroid_lat)) ? Number(incident.centroid_lat) : 31.5204;
  const lng = Number.isFinite(Number(incident.centroid_lng)) ? Number(incident.centroid_lng) : 74.3587;
  const types = preferredResourceTypes(category);
  const baseSpecialties = Array.from(new Set([category, "triage", "field_verification"]));

  return [
    {
      name: "RapidAid Alpha Response",
      resource_type: types[0],
      home_lat: lat - 0.010,
      home_lng: lng - 0.008,
      current_lat: lat - 0.010,
      current_lng: lng - 0.008,
      capacity: 4,
      metadata: {
        demo_seed: PROVIDER_BOOKING_SEED,
        seed_key: `${PROVIDER_BOOKING_SEED}:${incidentId}:alpha`,
        incident_id: incidentId,
        readiness_score: 0.96,
        average_speed_kph: 52,
        specialties: baseSpecialties,
      },
    },
    {
      name: "MetroLink Dispatch Unit",
      resource_type: types[1],
      home_lat: lat + 0.018,
      home_lng: lng + 0.012,
      current_lat: lat + 0.018,
      current_lng: lng + 0.012,
      capacity: 3,
      metadata: {
        demo_seed: PROVIDER_BOOKING_SEED,
        seed_key: `${PROVIDER_BOOKING_SEED}:${incidentId}:metro`,
        incident_id: incidentId,
        readiness_score: 0.88,
        average_speed_kph: 46,
        specialties: Array.from(new Set([category, "reroute", "public_guidance"])),
      },
    },
    {
      name: "CivicShield Support Team",
      resource_type: types[2],
      home_lat: lat - 0.024,
      home_lng: lng + 0.019,
      current_lat: lat - 0.024,
      current_lng: lng + 0.019,
      capacity: 5,
      metadata: {
        demo_seed: PROVIDER_BOOKING_SEED,
        seed_key: `${PROVIDER_BOOKING_SEED}:${incidentId}:civic`,
        incident_id: incidentId,
        readiness_score: 0.80,
        average_speed_kph: 42,
        specialties: Array.from(new Set([category, "shelter", "relief"])),
      },
    },
  ];
}

function metadataFor(resource: Json): Json {
  return asObject(resource.metadata);
}

async function ensureMockProviders(ctx: AgentContext, incident: Json): Promise<Json[]> {
  const templates = providerTemplatesForIncident(incident);
  const seedKeys = new Set(templates.map((item) => String(asObject(item.metadata).seed_key)));
  const incidentId = String(incident.id);

  const { data: existingRows, error: existingError } = await ctx.admin
    .from("resources")
    .select("*")
    .limit(200);
  if (existingError) throw new Error(`Failed to inspect mock providers: ${existingError.message}`);

  const existing = asArray<Json>(existingRows).filter((row) => {
    const metadata = metadataFor(row);
    return metadata.demo_seed === PROVIDER_BOOKING_SEED &&
      metadata.incident_id === incidentId &&
      seedKeys.has(String(metadata.seed_key));
  });
  const existingKeys = new Set(existing.map((row) => String(metadataFor(row).seed_key)));
  const missing = templates.filter((template) => !existingKeys.has(String(asObject(template.metadata).seed_key)));

  if (missing.length > 0) {
    const { error: insertError } = await ctx.admin.from("resources").insert(missing.map((template) => ({
      name: String(template.name),
      resource_type: String(template.resource_type),
      status: "available",
      home_lat: numberOrUndefined(template.home_lat),
      home_lng: numberOrUndefined(template.home_lng),
      current_lat: numberOrUndefined(template.current_lat),
      current_lng: numberOrUndefined(template.current_lng),
      capacity: clamp(Math.round(Number(template.capacity ?? 1)), 1, 20),
      assigned_incident_id: null,
      metadata: asObject(template.metadata),
    })));
    if (insertError) throw new Error(`Failed to seed mock providers: ${insertError.message}`);
  }

  const { data: refreshedRows, error: refreshedError } = await ctx.admin
    .from("resources")
    .select("*")
    .limit(200);
  if (refreshedError) throw new Error(`Failed to load mock providers: ${refreshedError.message}`);

  return asArray<Json>(refreshedRows)
    .filter((row) => {
      const metadata = metadataFor(row);
      return metadata.demo_seed === PROVIDER_BOOKING_SEED &&
        metadata.incident_id === incidentId &&
        seedKeys.has(String(metadata.seed_key));
    })
    .slice(0, 3);
}

function fitScoreFor(resource: Json, category: string): number {
  const normalized = category.toLowerCase();
  const metadata = metadataFor(resource);
  const specialties = asArray<string>(metadata.specialties).map((item) => item.toLowerCase());
  if (specialties.includes(normalized)) return 1;

  const resourceType = String(resource.resource_type ?? "");
  const preferred = preferredResourceTypes(normalized);
  const index = preferred.indexOf(resourceType);
  if (index === 0) return 0.92;
  if (index === 1) return 0.78;
  if (index === 2) return 0.66;
  return 0.45;
}

function rankMockProviders(incident: Json, providers: Json[]): Json[] {
  const category = stringOrDefault(incident.category, "unknown");
  const lat = Number.isFinite(Number(incident.centroid_lat)) ? Number(incident.centroid_lat) : 31.5204;
  const lng = Number.isFinite(Number(incident.centroid_lng)) ? Number(incident.centroid_lng) : 74.3587;
  const incidentId = String(incident.id);

  const ranked = providers.map((resource) => {
    const metadata = metadataFor(resource);
    const resourceLat = Number(resource.current_lat ?? resource.home_lat ?? lat);
    const resourceLng = Number(resource.current_lng ?? resource.home_lng ?? lng);
    const distanceMeters = Number.isFinite(resourceLat) && Number.isFinite(resourceLng)
      ? Math.round(haversineMeters(lat, lng, resourceLat, resourceLng))
      : 99999;
    const speedKph = clamp(Number(metadata.average_speed_kph ?? 42), 20, 80);
    const readinessScore = clamp(Number(metadata.readiness_score ?? 0.75), 0.25, 1);
    const etaSeconds = Math.round(distanceMeters / (speedKph * 1000 / 3600) + (1 - readinessScore) * 240);
    const isAvailable = resource.status === "available";
    const assignedHere = resource.assigned_incident_id === incidentId;
    const availabilityScore = isAvailable ? 1 : assignedHere ? 0.55 : 0.12;
    const capacityScore = clamp(Number(resource.capacity ?? 1) / 5, 0.2, 1);
    const fitScore = fitScoreFor(resource, category);
    const distanceScore = clamp(1 - distanceMeters / 14000, 0.05, 1);
    const etaScore = clamp(1 - etaSeconds / 1800, 0.05, 1);
    const totalScore = Math.round(100 * (0.32 * etaScore + 0.24 * distanceScore + 0.18 * availabilityScore + 0.14 * capacityScore + 0.12 * fitScore)) / 100;

    return {
      resource_id: resource.id,
      name: resource.name,
      resource_type: resource.resource_type,
      status: resource.status,
      capacity: resource.capacity,
      distance_meters: distanceMeters,
      eta_seconds: etaSeconds,
      availability_score: Math.round(availabilityScore * 100) / 100,
      capacity_score: Math.round(capacityScore * 100) / 100,
      fit_score: Math.round(fitScore * 100) / 100,
      total_score: totalScore,
      rationale: `${Math.max(1, Math.round(etaSeconds / 60))} min ETA, ${Math.round(distanceMeters / 100) / 10} km away, ${isAvailable ? "available" : assignedHere ? "already assigned here" : "not currently available"}, capacity ${resource.capacity ?? 1}, crisis-fit ${Math.round(fitScore * 100)}%.`,
    };
  });

  return ranked
    .sort((a, b) => Number(b.total_score) - Number(a.total_score))
    .map((item, index) => ({ ...item, rank: index + 1 }));
}

async function createProviderBooking(ctx: AgentContext, incident: Json, simulationRunId: string, actions: unknown[]): Promise<Json> {
  const incidentId = String(incident.id);
  const providers = await ensureMockProviders(ctx, incident);
  if (providers.length < 3) throw new Error("Provider booking requires three mock providers");

  const rankedProviders = rankMockProviders(incident, providers);
  const selected = rankedProviders.find((provider) => provider.status === "available") ?? rankedProviders[0];
  const selectedResource = providers.find((resource) => resource.id === selected.resource_id) ?? providers[0];
  const confirmationId = `CRISISX-${new Date().toISOString().slice(0, 10).replaceAll("-", "")}-${crypto.randomUUID().slice(0, 8).toUpperCase()}`;
  const criteria = {
    eta_weight: 0.32,
    distance_weight: 0.24,
    availability_weight: 0.18,
    capacity_weight: 0.14,
    crisis_type_fit_weight: 0.12,
  };
  const selectionReason = `Selected ${selected.name} because it had the best combined score across ETA, distance, availability, capacity, and ${incident.category ?? "crisis"} fit. ${selected.rationale}`;

  const updatedMetadata = {
    ...metadataFor(selectedResource),
    last_booking: {
      confirmation_id: confirmationId,
      incident_id: incidentId,
      simulation_run_id: simulationRunId,
      selected_at: new Date().toISOString(),
      selected_rank: selected.rank,
      selected_score: selected.total_score,
    },
  };

  const { error: resourceError } = await ctx.admin
    .from("resources")
    .update({
      status: "assigned_mock",
      assigned_incident_id: incidentId,
      metadata: updatedMetadata,
    })
    .eq("id", String(selected.resource_id));
  if (resourceError) throw new Error(`Failed to assign mock provider: ${resourceError.message}`);

  const bookingPayload = {
    booking_confirmation_id: confirmationId,
    selected_provider: selected,
    ranked_providers: rankedProviders,
    ranking_criteria: criteria,
    selection_reason: selectionReason,
    simulated_only: true,
    real_services_contacted: false,
  };

  const { data: action, error: actionError } = await ctx.admin
    .from("response_actions")
    .insert({
      incident_id: incidentId,
      action_type: "assign_resource",
      title: `Book mock provider: ${selected.name}`,
      description: selectionReason,
      priority: clamp(Math.round(Number(incident.severity ?? 3)), 1, 5),
      status: "ready",
      assigned_to: String(selected.name),
      payload: bookingPayload,
      created_by: ctx.userId,
    })
    .select("*")
    .single();
  if (actionError || !action) throw new Error(`Failed to create mock booking action: ${actionError?.message}`);

  const { data: ticket, error: ticketError } = await ctx.admin
    .from("emergency_tickets")
    .insert({
      incident_id: incidentId,
      simulation_run_id: simulationRunId,
      external_ref: confirmationId,
      ticket_type: "mock_provider_booking",
      priority: clamp(Math.round(Number(incident.severity ?? 3)), 1, 5),
      status: "assigned_mock",
      summary: `Mock dispatch booked: ${selected.name}`,
      details: selectionReason,
      payload: {
        ...bookingPayload,
        response_action_id: action.id,
        action_count_considered: actions.length,
      },
    })
    .select("*")
    .single();
  if (ticketError || !ticket) throw new Error(`Failed to create mock booking ticket: ${ticketError?.message}`);

  const output = {
    booking_confirmation_id: confirmationId,
    selected_provider: selected,
    ranked_providers: rankedProviders,
    ranking_criteria: criteria,
    selection_reason: selectionReason,
    response_action_id: action.id,
    emergency_ticket_id: ticket.id,
    simulated_only: true,
  };

  await ctx.admin.from("agent_logs").insert({
    agent_run_id: ctx.runId,
    agent_name: "Provider Booking Agent",
    step: "rank_and_book_mock_provider",
    status: "completed",
    message: `Booked ${selected.name} with confirmation ${confirmationId} after ranking three mock providers.`,
    input_payload: { incident_id: incidentId, simulation_run_id: simulationRunId, criteria },
    output_payload: output,
    confidence: 0.91,
    started_at: new Date().toISOString(),
    completed_at: new Date().toISOString(),
  });

  return output;
}

async function createSimulation(ctx: AgentContext, incidentId: string, scenario: string, actions: unknown[]): Promise<Json> {
  const { data: incident, error: incidentError } = await ctx.admin
    .from("incidents")
    .select("*")
    .eq("id", incidentId)
    .single();
  if (incidentError || !incident) throw new Error(`Incident not found for simulation: ${incidentError?.message}`);

  const { data: run, error: runError } = await ctx.admin
    .from("simulation_runs")
    .insert({
      incident_id: incidentId,
      agent_run_id: ctx.runId,
      status: "running",
      scenario,
      input_payload: { actions, simulation_notice: "safe mock execution only" },
      created_by: ctx.userId,
    })
    .select("*")
    .single();
  if (runError || !run) throw new Error(`Failed to create simulation run: ${runError?.message}`);

  const severity = Number(incident.severity ?? 1);
  const actionCount = Math.max(actions.length, 1);
  const beforeExposure = Math.round(200 + severity * 180 + actionCount * 35);
  const afterExposure = Math.round(beforeExposure * (1 - clamp(0.12 + actionCount * 0.055, 0.12, 0.48)));
  const beforeEta = Math.round(900 + severity * 220);
  const afterEta = Math.round(beforeEta * (1 - clamp(0.08 + actionCount * 0.04, 0.08, 0.34)));

  await ctx.admin.from("simulation_metrics").insert([
    {
      simulation_run_id: run.id,
      incident_id: incidentId,
      metric_name: "estimated_population_exposure",
      before_value: beforeExposure,
      after_value: afterExposure,
      unit: "people",
      delta: afterExposure - beforeExposure,
      payload: { formula: "severity and planned action count based mock impact model" },
    },
    {
      simulation_run_id: run.id,
      incident_id: incidentId,
      metric_name: "estimated_response_eta",
      before_value: beforeEta,
      after_value: afterEta,
      unit: "seconds",
      delta: afterEta - beforeEta,
      payload: { formula: "traffic-aware reroute and coordination mock impact model" },
    },
    {
      simulation_run_id: run.id,
      incident_id: incidentId,
      metric_name: "operator_confidence",
      before_value: Number(incident.confidence ?? 0),
      after_value: clamp(Number(incident.confidence ?? 0) + 0.08 + actionCount * 0.03, 0, 0.98),
      unit: "score",
      payload: { bounded: true },
    },
  ]);

  const lat = Number(incident.centroid_lat);
  const lng = Number(incident.centroid_lng);
  if (Number.isFinite(lat) && Number.isFinite(lng)) {
    await ctx.admin.from("blocked_segments").insert({
      incident_id: incidentId,
      simulation_run_id: run.id,
      start_lat: lat - 0.003,
      start_lng: lng - 0.003,
      end_lat: lat + 0.003,
      end_lng: lng + 0.003,
      reason: `Mock closure around ${incident.title}`,
      severity: clamp(Math.round(severity), 1, 5),
      payload: { simulated_only: true, real_traffic_modified: false },
    });
  }

  let providerBooking: Json = { status: "skipped" };
  try {
    providerBooking = await createProviderBooking(ctx, incident as Json, String(run.id), actions);
  } catch (error) {
    providerBooking = {
      status: "booking_failed",
      error: error instanceof Error ? error.message : String(error),
      simulated_only: true,
    };
    await writeRecoveryAgentLog(
      ctx,
      "Provider Booking Agent",
      "rank_and_book_mock_provider_recovery",
      `Provider booking could not complete, but simulation metrics were preserved: ${providerBooking.error}`,
      providerBooking,
    );
  }

  await ctx.admin
    .from("response_actions")
    .update({ status: "ready" })
    .eq("incident_id", incidentId)
    .in("status", ["planned", "simulating"]);

  await ctx.admin
    .from("simulation_runs")
    .update({
      status: "completed",
      completed_at: new Date().toISOString(),
      output_payload: {
        estimated_population_exposure: { before: beforeExposure, after: afterExposure },
        estimated_response_eta_seconds: { before: beforeEta, after: afterEta },
        provider_booking: providerBooking,
        simulated_only: true,
      },
    })
    .eq("id", run.id);

  return {
    simulation_run_id: run.id,
    status: "completed",
    estimated_population_exposure: { before: beforeExposure, after: afterExposure },
    estimated_response_eta_seconds: { before: beforeEta, after: afterEta },
    provider_booking: providerBooking,
    simulated_only: true,
  };
}

async function nearbyRecentSignals(admin: SupabaseClient, latitude?: number, longitude?: number, category?: string): Promise<unknown[]> {
  let query = admin
    .from("normalized_signals")
    .select("*, signals!inner(id, created_at, urgency, report_text, source_type)")
    .gte("created_at", new Date(Date.now() - 6 * 60 * 60 * 1000).toISOString())
    .limit(80);

  if (category) query = query.eq("category", category);
  const { data, error } = await query;
  if (error) throw new Error(`Failed to fetch nearby signals: ${error.message}`);

  if (latitude === undefined || longitude === undefined) return data ?? [];
  return (data ?? []).filter((row) => {
    const lat = Number(row.latitude);
    const lng = Number(row.longitude);
    return Number.isFinite(lat) && Number.isFinite(lng) && haversineMeters(latitude, longitude, lat, lng) <= 3000;
  });
}

async function nearbyIncidents(admin: SupabaseClient, latitude?: number, longitude?: number): Promise<unknown[]> {
  const { data, error } = await admin
    .from("incidents")
    .select("*")
    .in("status", ["detecting", "active", "monitoring", "mitigating"])
    .gte("updated_at", new Date(Date.now() - 12 * 60 * 60 * 1000).toISOString())
    .limit(50);
  if (error) throw new Error(`Failed to fetch nearby incidents: ${error.message}`);

  if (latitude === undefined || longitude === undefined) return data ?? [];
  return (data ?? []).filter((row) => {
    const lat = Number(row.centroid_lat);
    const lng = Number(row.centroid_lng);
    return Number.isFinite(lat) && Number.isFinite(lng) && haversineMeters(latitude, longitude, lat, lng) <= 5000;
  });
}

function routeProbeFor(latitude?: number, longitude?: number) {
  if (latitude === undefined || longitude === undefined) return undefined;
  return {
    origin: { latitude: latitude - 0.018, longitude: longitude - 0.014 },
    destination: { latitude: latitude + 0.018, longitude: longitude + 0.014 },
  };
}

async function persistEvidence(admin: SupabaseClient, incidentId: string, signalId: string, evidenceOutput: Json) {
  const rows = [];
  const weather = asObject(evidenceOutput.weather);
  if (Object.keys(weather).length > 0) {
    rows.push({
      incident_id: incidentId,
      signal_id: signalId,
      evidence_type: "weather",
      source_name: String(weather.provider ?? "weather"),
      title: String(weather.description ?? weather.condition ?? "Weather observation"),
      confidence: 0.7,
      payload: weather,
    });
  }
  for (const item of asArray<Json>(evidenceOutput.news)) {
    rows.push({
      incident_id: incidentId,
      signal_id: signalId,
      evidence_type: "news",
      source_name: "Exa AI",
      title: typeof item.title === "string" ? item.title : "News corroboration",
      url: typeof item.url === "string" ? item.url : null,
      confidence: numberOrUndefined(item.confidence) ?? 0.55,
      payload: item,
    });
  }
  for (const item of asArray<Json>(evidenceOutput.route_options)) {
    rows.push({
      incident_id: incidentId,
      signal_id: signalId,
      evidence_type: "route",
      source_name: "Google Routes",
      title: "Traffic-aware route candidate",
      confidence: 0.6,
      payload: item,
    });
  }
  if (rows.length > 0) {
    const { error } = await admin.from("incident_evidence").insert(rows);
    if (error) throw new Error(`Failed to persist incident evidence: ${error.message}`);
  }
}

function rulesSeverity(signal: Json, cluster: unknown[], evidence: Json): Json {
  const urgency = clamp(Math.round(Number(signal.urgency ?? 3)), 1, 5);
  const clusterBoost = Math.min(1.1, Math.log2(Math.max(cluster.length, 1)) * 0.45);
  const weather = asObject(evidence.weather);
  const weatherBoost = Number(weather.rain_1h_mm ?? 0) > 10 || Number(weather.wind_mps ?? 0) > 12 ? 0.8 : 0;
  const newsBoost = Math.min(0.7, asArray(evidence.news).length * 0.14);
  const routeBoost = Math.min(0.5, asArray(evidence.route_options).length * 0.1);
  const raw = urgency + clusterBoost + weatherBoost + newsBoost + routeBoost - 0.6;
  const severity = clamp(Math.round(raw), 1, 5);
  const confidence = clamp(0.28 + cluster.length * 0.08 + asArray(evidence.news).length * 0.06 + (Object.keys(weather).length ? 0.12 : 0), 0.25, 0.96);
  return { severity, confidence, components: { urgency, clusterBoost, weatherBoost, newsBoost, routeBoost, raw } };
}

async function saveLocationAlias(admin: SupabaseClient, values: Json): Promise<void> {
  const { error } = await admin
    .from("location_aliases")
    .insert(values);

  if (!error) return;

  const message = error.message ?? "";
  if (error.code === "23505" || message.includes("duplicate key value")) {
    return;
  }
  throw new Error(`Failed to save location alias: ${message}`);
}

async function processSignal(admin: SupabaseClient, userId: string, signalId: string, existingRun?: Json): Promise<Json> {
  const { data: signal, error: signalError } = await admin.from("signals").select("*").eq("id", signalId).single();
  if (signalError || !signal) throw new HttpError(404, `Signal not found: ${signalError?.message ?? signalId}`);

  let run: Json;
  if (existingRun) {
    const { data: updatedRun, error: updateRunError } = await admin
      .from("agent_runs")
      .update({
        status: "running",
        input_payload: { signal },
      })
      .eq("id", String(existingRun.id))
      .select("*")
      .maybeSingle();
    if (updateRunError) throw new Error(`Failed to start existing agent run: ${updateRunError.message}`);
    run = (updatedRun ?? existingRun) as Json;
  } else {
    const { data: insertedRun, error: runError } = await admin
      .from("agent_runs")
      .insert({
        trigger_type: "signal",
        trigger_id: signalId,
        status: "running",
        input_payload: { signal },
        created_by: userId,
      })
      .select("*")
      .single();
    if (runError || !insertedRun) throw new Error(`Failed to create agent run: ${runError?.message}`);
    run = insertedRun as Json;
  }

  const runId = String(run.id);
  const ctx: AgentContext = { admin, userId, runId };

  try {
    await admin.from("signals").update({ status: "normalizing" }).eq("id", signalId);
    const normalized = await runAgent(
      ctx,
      "Signal Normalizer Agent",
      "normalize_signal",
      `You normalize noisy public crisis reports written in English, Urdu, or Roman Urdu.
Output schema:
{
  "normalized_text": string,
  "translated_text": string,
  "language": string,
  "category": string,
  "urgency": 1-5,
  "severity_hint": 1-5,
  "location_candidates": string[],
  "entities": object,
  "confidence": 0-1,
  "summary": string
}`,
      { signal },
      ["write_agent_log"],
    );

    const { data: normalizedRow, error: normalizedError } = await admin
      .from("normalized_signals")
      .insert({
        signal_id: signalId,
        normalized_text: String(normalized.normalized_text ?? signal.report_text),
        translated_text: typeof normalized.translated_text === "string" ? normalized.translated_text : null,
        location_text: asArray<string>(normalized.location_candidates)[0] ?? signal.location_text,
        category: String(normalized.category ?? signal.category ?? "unknown"),
        severity_hint: clamp(Math.round(Number(normalized.severity_hint ?? signal.urgency ?? 3)), 1, 5),
        entities: asObject(normalized.entities),
        model: PRIMARY_MODEL,
        confidence: clamp(Number(normalized.confidence ?? 0), 0, 1),
      })
      .select("*")
      .single();
    if (normalizedError || !normalizedRow) throw new Error(`Failed to insert normalized signal: ${normalizedError?.message}`);
    await admin.from("signals").update({
      status: "normalized",
      category: normalizedRow.category,
      urgency: clamp(Math.round(Number(normalized.urgency ?? signal.urgency ?? 3)), 1, 5),
      normalized_signal_id: normalizedRow.id,
      confidence: normalizedRow.confidence,
    }).eq("id", signalId);

    await admin.from("signals").update({ status: "geocoding" }).eq("id", signalId);
    const geo = await runAgent(
      ctx,
      "Geo Resolver Agent",
      "resolve_geo",
      `Resolve coordinates for the normalized signal. You must call geocode_locations when any location text or candidate exists.
Output schema:
{
  "location": {"name": string, "latitude": number|null, "longitude": number|null, "confidence": number, "source": string},
  "aliases": [{"alias": string, "canonical_name": string}],
  "unresolved_reason": string|null,
  "confidence": 0-1,
  "summary": string
}`,
      { signal, normalized_signal: normalizedRow, candidates: normalized.location_candidates, original_location_text: signal.location_text },
      ["geocode_locations", "write_agent_log"],
    );

    const location = asObject(geo.location);
    const lat = numberOrUndefined(location.latitude) ?? numberOrUndefined(signal.latitude);
    const lng = numberOrUndefined(location.longitude) ?? numberOrUndefined(signal.longitude);
    if (lat !== undefined && lng !== undefined) {
      await admin.from("signals").update({ latitude: lat, longitude: lng, status: "enriched" }).eq("id", signalId);
      await admin.from("normalized_signals").update({ latitude: lat, longitude: lng, status: "geocoded" }).eq("id", normalizedRow.id);
      const savedAliases = new Set<string>();
      for (const alias of asArray<Json>(geo.aliases)) {
        const aliasText = typeof alias.alias === "string" ? sanitizedAlias(alias.alias) : undefined;
        const canonical = sanitizedAlias(
          typeof alias.canonical_name === "string" ? alias.canonical_name : String(location.name ?? aliasText ?? "Resolved location"),
        );
        const aliasKey = aliasText ? `${aliasText.toLocaleLowerCase()}|${canonical.toLocaleLowerCase()}` : "";
        if (aliasText && !savedAliases.has(aliasKey)) {
          savedAliases.add(aliasKey);
          await saveLocationAlias(admin, {
            alias: aliasText,
            canonical_name: canonical,
            latitude: lat,
            longitude: lng,
            source: "geo_resolver_agent",
            evidence: { signal_id: signalId, agent_run_id: runId },
          });
        }
      }
    }

    const routeProbe = routeProbeFor(lat, lng);
    const evidence = await runAgent(
      ctx,
      "Evidence Agent",
      "collect_evidence",
      `Collect real current evidence. If coordinates are available, call fetch_weather.
Call search_latest_web_news for corroborating latest web/news. If route probe is supplied, call compute_route_alternatives.
Output schema:
{
  "weather": object,
  "news": [{"title": string, "url": string, "publishedDate": string, "summary": string, "confidence": number}],
  "route_options": [{"eta_seconds": number, "distance_meters": number, "polyline": string}],
  "corroboration_score": number,
  "confidence": 0-1,
  "summary": string
}`,
      {
        normalized_signal: normalizedRow,
        location: { latitude: lat, longitude: lng, name: location.name },
        query: `${normalizedRow.category} ${normalizedRow.normalized_text}`,
        route_probe: routeProbe,
      },
      ["fetch_weather", "search_latest_web_news", "compute_route_alternatives", "write_agent_log"],
    );

    const cluster = await nearbyRecentSignals(admin, lat, lng, normalizedRow.category);
    const incidents = await nearbyIncidents(admin, lat, lng);
    const detected = await runAgent(
      ctx,
      "Crisis Detector Agent",
      "detect_or_cluster_incident",
      `Cluster the new normalized signal with nearby recent signals and active incidents.
Prefer updating an existing incident only when location, time, category, and narrative align.
You may call upsert_incident with your decision.
Output schema:
{
  "incident_id": string|null,
  "is_new_incident": boolean,
  "title": string,
  "description": string,
  "category": string,
  "status": "active"|"monitoring"|"detecting",
  "severity_seed": 1-5,
  "confidence": 0-1,
  "cluster_signal_ids": string[],
  "rationale": string
}`,
      {
        signal,
        normalized_signal: normalizedRow,
        location: { latitude: lat, longitude: lng },
        nearby_recent_signals: cluster,
        nearby_active_incidents: incidents,
        evidence_summary: evidence,
      },
      ["upsert_incident", "write_agent_log"],
    );

    const incident = await ensureIncident(admin, detected, normalizedRow, evidence, lat, lng);
    await persistEvidence(admin, String(incident.id), signalId, evidence);
    await admin.from("signals").update({ status: "clustered" }).eq("id", signalId);
    await admin.from("normalized_signals").update({ status: "clustered" }).eq("id", normalizedRow.id);

    const ruleScore = rulesSeverity(signal, cluster, evidence);
    let severity: Json;
    try {
      severity = await runAgent(
        ctx,
        "Severity Agent",
        "score_severity",
        `Blend deterministic scoring with AI judgment. Do not lower severity below obvious life-safety clues.
Output schema:
{
  "severity": 1-5,
  "confidence": 0-1,
  "ai_explanation": string,
  "rule_components": object,
  "recommended_status": "active"|"monitoring"|"mitigating",
  "summary": string
}`,
        { signal, normalized_signal: normalizedRow, incident, evidence, cluster_size: cluster.length, rule_score: ruleScore },
        ["write_agent_log"],
      );
    } catch (error) {
      severity = fallbackSeverity(ruleScore, incident);
      await writeRecoveryAgentLog(
        ctx,
        "Severity Agent",
        "score_severity_recovery",
        `Severity recovered after model failure: ${error instanceof Error ? error.message : String(error)}`,
        severity,
      );
    }

    const finalSeverity = clamp(Math.round(Number(severity.severity ?? ruleScore.severity)), 1, 5);
    const finalConfidence = clamp(Number(severity.confidence ?? ruleScore.confidence), 0, 1);
    const { data: updatedIncident, error: incidentUpdateError } = await admin
      .from("incidents")
      .update({
        severity: finalSeverity,
        confidence: finalConfidence,
        status: String(severity.recommended_status ?? incident.status ?? "active"),
        summary: {
          ...asObject(incident.summary),
          severity_explanation: severity.ai_explanation,
          rule_score: ruleScore,
          cluster_signal_ids: detected.cluster_signal_ids,
        },
        evidence_summary: evidence,
      })
      .eq("id", incident.id)
      .select("*")
      .maybeSingle();
    if (incidentUpdateError) throw new Error(`Failed to update incident severity: ${incidentUpdateError.message}`);
    const incidentForPlanning = (updatedIncident ?? await upsertIncident(admin, {
      incident_id: incident.id,
      title: incident.title,
      description: incident.description,
      category: incident.category,
      status: String(severity.recommended_status ?? incident.status ?? "active"),
      severity: finalSeverity,
      confidence: finalConfidence,
      centroid_lat: incident.centroid_lat,
      centroid_lng: incident.centroid_lng,
      summary: {
        ...asObject(incident.summary),
        severity_explanation: severity.ai_explanation,
        rule_score: ruleScore,
        cluster_signal_ids: detected.cluster_signal_ids,
      },
      evidence_summary: evidence,
    })) as Record<string, unknown>;

    let plan: Json;
    try {
      plan = await runAgent(
        ctx,
        "Response Planner Agent",
        "plan_response",
        `Create coordinated simulated response actions. Prefer returning the JSON actions list quickly; call create_response_action only when you are certain the required incident_id is present.
Actions must be safe app-owned work: reroute recommendations, mock alerts/tickets, mock resource assignment, monitoring, or field checks.
Output schema:
{
  "actions": [{"action_type": string, "title": string, "description": string, "priority": 1-5, "payload": object}],
  "coordination_notes": string,
  "confidence": 0-1,
  "summary": string
}`,
        { incident: incidentForPlanning, normalized_signal: normalizedRow, evidence },
        ["create_response_action", "write_agent_log"],
      );
    } catch (error) {
      plan = fallbackResponsePlan(incidentForPlanning, evidence);
      await writeRecoveryAgentLog(
        ctx,
        "Response Planner Agent",
        "plan_response_recovery",
        `Planner recovered after model/tool failure: ${error instanceof Error ? error.message : String(error)}`,
        plan,
      );
    }

    const actions = await ensureResponseActions(ctx, String(incidentForPlanning.id), plan);

    const simulation = await runAgent(
      ctx,
      "Simulation Agent",
      "execute_safe_mock_response",
      `Execute safe mock actions. You must call run_simulation. Create mock emergency tickets and mock alerts when appropriate.
Never claim real emergency services were contacted or real Google traffic changed.
Output schema:
{
  "simulation_run_id": string|null,
  "mock_tickets": object[],
  "mock_alerts": object[],
  "metrics": object,
  "safety_notice": string,
  "confidence": 0-1,
  "summary": string
}`,
      { incident: incidentForPlanning, actions, evidence },
      ["run_simulation", "create_mock_emergency_ticket", "create_mock_alert", "write_agent_log"],
    );

    const simulationRunId = typeof simulation.simulation_run_id === "string"
      ? simulation.simulation_run_id
      : (await createSimulation(ctx, String(incidentForPlanning.id), "safe_response_execution", actions)).simulation_run_id;

    const trace = await runAgent(
      ctx,
      "Trace Agent",
      "summarize_trace",
      `Summarize the trace for operator audit. Call write_agent_log with a final audit marker.
Output schema:
{
  "trace_summary": string,
  "audit_points": string[],
  "final_state": object,
  "confidence": 0-1,
  "summary": string
}`,
      { run_id: runId, signal_id: signalId, incident_id: incidentForPlanning.id, simulation_run_id: simulationRunId },
      ["write_agent_log"],
    );

    await admin.from("system_status").upsert({
      status_key: "agent_orchestrator",
      status: "healthy",
      message: "Last agent pipeline completed",
      payload: { run_id: runId, signal_id: signalId, incident_id: incidentForPlanning.id, trace },
      updated_at: new Date().toISOString(),
    });

    const output = {
      signal_id: signalId,
      normalized_signal_id: normalizedRow.id,
      incident_id: incidentForPlanning.id,
      simulation_run_id: simulationRunId,
      run_id: runId,
      status: "completed",
    };
    await admin.from("agent_runs").update({
      status: "completed",
      ended_at: new Date().toISOString(),
      output_payload: output,
    }).eq("id", runId);
    return output;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await admin.from("signals").update({ status: "failed", raw_payload: { ...asObject(signal.raw_payload), failure: message } }).eq("id", signalId);
    await admin.from("agent_runs").update({
      status: "failed",
      ended_at: new Date().toISOString(),
      error: message,
    }).eq("id", runId);
    await admin.from("system_status").upsert({
      status_key: "agent_orchestrator",
      status: "degraded",
      message,
      payload: { run_id: runId, signal_id: signalId },
      updated_at: new Date().toISOString(),
    });
    throw error;
  }
}

async function ensureIncident(
  admin: SupabaseClient,
  detected: Json,
  normalizedRow: Json,
  evidence: Json,
  lat?: number,
  lng?: number,
): Promise<Json> {
  if (typeof detected.incident_id === "string" && detected.incident_id.length > 0) {
    const { data } = await admin.from("incidents").select("*").eq("id", detected.incident_id).maybeSingle();
    if (data) return data as Json;
  }

  return await upsertIncident(admin, {
    title: detected.title ?? `${String(normalizedRow.category ?? "Crisis")} near ${String(normalizedRow.location_text ?? "reported area")}`,
    description: detected.description ?? normalizedRow.normalized_text,
    category: detected.category ?? normalizedRow.category ?? "unknown",
    status: detected.status ?? "active",
    severity: detected.severity_seed ?? normalizedRow.severity_hint ?? 2,
    confidence: detected.confidence ?? 0.45,
    centroid_lat: lat,
    centroid_lng: lng,
    summary: {
      detector_rationale: detected.rationale,
      cluster_signal_ids: detected.cluster_signal_ids,
    },
    evidence_summary: evidence,
  });
}

async function ensureResponseActions(ctx: AgentContext, incidentId: string, plan: Json): Promise<Json[]> {
  const { data: existing } = await ctx.admin
    .from("response_actions")
    .select("*")
    .eq("incident_id", incidentId)
    .order("priority", { ascending: false });
  if (existing && existing.length > 0) return existing as Json[];

  const actions = asArray<Json>(plan.actions).slice(0, 6);
  const created: Json[] = [];
  for (const action of actions) {
    const result = await toolHandlers.create_response_action(ctx, {
      incident_id: incidentId,
      action_type: action.action_type ?? "monitor",
      title: action.title ?? "Monitor incident",
      description: action.description,
      priority: action.priority ?? 3,
      payload: action.payload ?? {},
    });
    created.push(result);
  }
  return created;
}

function fallbackResponsePlan(incident: Json, evidence: Json): Json {
  const category = stringOrDefault(incident.category, "crisis");
  const title = stringOrDefault(incident.title, "reported incident");
  const severity = clamp(Math.round(Number(incident.severity ?? 3)), 1, 5);
  const location = stringOrDefault(incident.location_text, stringOrDefault(incident.centroid_label, "reported area"));
  const evidenceKeys = Object.keys(evidence).slice(0, 5);

  return {
    actions: [
      {
        action_type: "monitor",
        title: `Monitor ${title}`,
        description: `Keep the ${category} incident under active simulated monitoring while new signals and evidence arrive.`,
        priority: severity,
        payload: { source: "deterministic_recovery_plan", evidence_keys: evidenceKeys, simulated_only: true },
      },
      {
        action_type: "public_guidance",
        title: "Prepare app safety guidance",
        description: `Publish an in-app advisory for people near ${location}. This is simulated guidance only and does not contact real emergency services.`,
        priority: Math.max(3, severity - 1),
        payload: { source: "deterministic_recovery_plan", real_services_contacted: false, simulated_only: true },
      },
      {
        action_type: "field_check",
        title: "Create mock field verification task",
        description: "Create a mock verification action for operators to review route, weather, and news evidence before escalation.",
        priority: Math.max(2, severity - 1),
        payload: { source: "deterministic_recovery_plan", simulated_only: true },
      },
    ],
    coordination_notes: "Generated by deterministic recovery because the model planner did not complete in time.",
    confidence: 0.62,
    summary: "Response Planner recovered with safe simulated response actions.",
  };
}

function fallbackSeverity(ruleScore: Json, incident: Json): Json {
  const severity = clamp(Math.round(Number(ruleScore.severity ?? incident.severity ?? 3)), 1, 5);
  const confidence = clamp(Number(ruleScore.confidence ?? incident.confidence ?? 0.5), 0.25, 0.96);
  const status = severity >= 4 ? "active" : severity >= 3 ? "monitoring" : "monitoring";

  return {
    severity,
    confidence,
    ai_explanation: "Recovered from a model timeout using deterministic severity rules so the agent pipeline can continue.",
    rule_components: asObject(ruleScore.components),
    recommended_status: status,
    recovery: {
      source: "deterministic_severity_recovery",
      primary_model: PRIMARY_MODEL,
      fallback_model: FALLBACK_MODEL,
    },
    summary: "Severity Agent recovered with rules-based scoring.",
  };
}

async function writeRecoveryAgentLog(ctx: AgentContext, agentName: string, step: string, message: string, output: Json) {
  await ctx.admin
    .from("agent_logs")
    .insert({
      agent_run_id: ctx.runId,
      agent_name: agentName,
      step,
      status: "completed",
      message,
      output_payload: output,
      confidence: numberOrUndefined(output.confidence),
      started_at: new Date().toISOString(),
      completed_at: new Date().toISOString(),
    });
}

async function startSignalProcessing(admin: SupabaseClient, userId: string, signalId: string): Promise<Json> {
  const { data: signal, error: signalError } = await admin.from("signals").select("*").eq("id", signalId).single();
  if (signalError || !signal) throw new HttpError(404, `Signal not found: ${signalError?.message ?? signalId}`);

  const { data: activeRuns, error: activeError } = await admin
    .from("agent_runs")
    .select("*")
    .eq("trigger_type", "signal")
    .eq("trigger_id", signalId)
    .in("status", ["queued", "running"])
    .order("started_at", { ascending: false })
    .limit(1);
  if (activeError) throw new Error(`Failed to inspect active runs: ${activeError.message}`);

  const activeRun = Array.isArray(activeRuns) ? activeRuns[0] : undefined;
  if (activeRun) {
    const { data: latestLogs } = await admin
      .from("agent_logs")
      .select("created_at,completed_at,status,agent_name,step")
      .eq("agent_run_id", activeRun.id)
      .order("created_at", { ascending: false })
      .limit(1);
    const latestLog = Array.isArray(latestLogs) ? latestLogs[0] : undefined;
    const activeRunIsStale = isOlderThan(latestLog?.completed_at ?? latestLog?.created_at ?? activeRun.started_at, STALE_RUN_MS);

    if (!activeRunIsStale) {
      return {
        status: "accepted",
        already_running: true,
        signal_id: signalId,
        run_id: activeRun.id,
      };
    }

    await admin
      .from("agent_runs")
      .update({
        status: "failed",
        ended_at: new Date().toISOString(),
        error: "Recovered stale running pipeline; a fresh run was queued.",
      })
      .eq("id", activeRun.id);

    await admin
      .from("agent_logs")
      .update({
        status: "failed",
        error: "Step timed out without a heartbeat; superseded by a recovery run.",
        completed_at: new Date().toISOString(),
      })
      .eq("agent_run_id", activeRun.id)
      .eq("status", "running");
  }

  const { data: run, error: runError } = await admin
    .from("agent_runs")
    .insert({
      trigger_type: "signal",
      trigger_id: signalId,
      status: "queued",
      input_payload: { signal, async_start: true },
      created_by: userId,
    })
    .select("*")
    .single();
  if (runError || !run) throw new Error(`Failed to queue agent run: ${runError?.message}`);

  await admin.from("signals").update({ status: "queued" }).eq("id", signalId);
  await admin.from("system_status").upsert({
    status_key: "agent_orchestrator",
    status: "running",
    message: "Agent pipeline accepted and streaming progress through Supabase",
    payload: { signal_id: signalId, run_id: run.id, async_start: true },
    updated_at: new Date().toISOString(),
  });

  queueBackgroundTask(processSignal(adminClient(), userId, signalId, run as Json));

  return {
    status: "accepted",
    signal_id: signalId,
    run_id: run.id,
  };
}

async function generateApiSignal(admin: SupabaseClient, userId: string, body: Json): Promise<Json> {
  const locationText = String(body.location_text ?? "").trim();
  if (!locationText) throw new HttpError(400, "generate_api_signal requires location_text");

  const geocode = await toolHandlers.geocode_locations(
    { admin, userId, runId: crypto.randomUUID() },
    { locations: [locationText], region_bias: body.region_bias ?? "PK" },
  );
  const first = asObject(asArray<Json>(asObject(asArray<Json>(geocode.results)[0]).candidates)[0]);
  const lat = numberOrUndefined(first.latitude);
  const lng = numberOrUndefined(first.longitude);
  if (lat === undefined || lng === undefined) throw new Error("Unable to resolve location for generated API signal");

  const weather = await toolHandlers.fetch_weather({ admin, userId, runId: crypto.randomUUID() }, { latitude: lat, longitude: lng });
  const news = await toolHandlers.search_latest_web_news(
    { admin, userId, runId: crypto.randomUUID() },
    { query: `${locationText} weather traffic emergency`, location: locationText, category: "news", hours_back: 72 },
  );

  const condition = String(weather.description ?? weather.condition ?? "current conditions");
  const reportText = `Backend API signal for ${locationText}: weather indicates ${condition}; latest web/news corroboration count ${asArray(news.results).length}.`;

  const { data: signal, error } = await admin
    .from("signals")
    .insert({
      submitted_by: userId,
      source_type: "simulated_api",
      report_text: reportText,
      category: String(body.category ?? "environment"),
      urgency: clamp(Math.round(Number(body.urgency ?? 3)), 1, 5),
      location_text: locationText,
      latitude: lat,
      longitude: lng,
      raw_payload: {
        source: "ciro-agent.generate_api_signal",
        weather,
        news,
        simulated_api_signal: true,
      },
    })
    .select("*")
    .single();
  if (error || !signal) throw new Error(`Failed to create generated API signal: ${error?.message}`);
  const output = await startSignalProcessing(admin, userId, signal.id);
  return { signal, pipeline: output };
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  try {
    const user = await getAuthedUser(req);
    const admin = adminClient();
    const body = await req.json().catch(() => ({}));
    const action = String(body.action ?? "process_signal");

    if (action === "process_signal" || action === "start_processing") {
      const signalId = String(body.signal_id ?? "");
      if (!signalId) throw new HttpError(400, "signal_id is required");
      return jsonResponse(await startSignalProcessing(admin, user.id, signalId), 202);
    }

    if (action === "process_signal_sync") {
      const signalId = String(body.signal_id ?? "");
      if (!signalId) throw new HttpError(400, "signal_id is required");
      return jsonResponse(await processSignal(admin, user.id, signalId));
    }

    if (action === "run_simulation") {
      const incidentId = String(body.incident_id ?? "");
      if (!incidentId) throw new HttpError(400, "incident_id is required");
      const { data: run, error } = await admin.from("agent_runs").insert({
        trigger_type: "simulation",
        trigger_id: incidentId,
        status: "running",
        input_payload: body,
        created_by: user.id,
      }).select("*").single();
      if (error || !run) throw new Error(`Failed to create simulation agent run: ${error?.message}`);
      const ctx = { admin, userId: user.id, runId: run.id };
      const output = await createSimulation(ctx, incidentId, String(body.scenario ?? "manual_safe_response_execution"), asArray(body.actions));
      await admin.from("agent_runs").update({ status: "completed", ended_at: new Date().toISOString(), output_payload: output }).eq("id", run.id);
      return jsonResponse(output);
    }

    if (action === "generate_api_signal") {
      return jsonResponse(await generateApiSignal(admin, user.id, body));
    }

    throw new HttpError(400, `Unsupported action: ${action}`);
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    const message = error instanceof Error ? error.message : String(error);
    return jsonResponse({ error: message }, status);
  }
});
