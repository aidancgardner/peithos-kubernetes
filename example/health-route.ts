import { NextResponse } from 'next/server'

// Liveness and readiness for the container orchestrator.
//
// Deliberately does NOT touch Supabase, Stripe or fal. A readiness probe that
// depends on a third party takes your own pods out of rotation when that third
// party has a bad minute, which is the opposite of what it is for.
//
// No top-level consts here that read env vars, per rule 8 in CLAUDE.md: this
// file is compiled at build time and must not need an environment to do it.

export const dynamic = 'force-dynamic'

export function GET() {
  return NextResponse.json({
    ok: true,
    service: 'peithos-web',
    // Set by the Deployment so you can see which build answered.
    release: process.env.APP_RELEASE ?? 'unknown',
    time: new Date().toISOString(),
  })
}
