import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

serve(async (req) => {
  try {
    const { user_id, type, title, body, data } = await req.json()

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // Get all tokens for this user
    const { data: tokens, error } = await supabase
      .from('device_tokens')
      .select('fcm_token')
      .eq('user_id', user_id)
      .eq('notifications_enabled', true)

    console.log('Tokens found:', tokens?.length, 'Error:', error)

    if (!tokens?.length) {
      return new Response(JSON.stringify({ sent: 0, reason: 'no tokens' }), {
        headers: { 'Content-Type': 'application/json' }
      })
    }

    const serviceAccount = JSON.parse(Deno.env.get('FIREBASE_SERVICE_ACCOUNT')!)
    const projectId = Deno.env.get('FIREBASE_PROJECT_ID')!

    // Get OAuth token using service account
    const accessToken = await getFirebaseToken(serviceAccount)
    console.log('Got access token:', accessToken ? 'yes' : 'no')

    let sent = 0

    // Firebase data payload values must be strings
    const stringData: Record<string, string> = {
      type: String(type || ''),
      ...Object.fromEntries(
        Object.entries(data || {}).map(([key, value]) => [key, String(value ?? '')])
      )
    }

    for (const { fcm_token } of tokens) {
      try {
        const fcmRes = await fetch(
          `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
          {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${accessToken}`,
              'Content-Type': 'application/json'
            },
            body: JSON.stringify({
              message: {
                token: fcm_token,
                notification: {
                  title: title || 'FaceMeet',
                  body: body || ''
                },
                data: stringData,
                android: {
                  priority: 'high',
                  notification: {
                    channel_id: 'facemeet_notifications',
                    sound: 'default'
                  }
                },
                apns: {
                  headers: {
                    'apns-priority': '10',
                    'apns-push-type': 'alert'
                  },
                  payload: {
                    aps: {
                      sound: 'default',
                      badge: 1
                    }
                  }
                }
              }
            })
          }
        )

        const fcmData = await fcmRes.json()
        console.log('FCM response:', JSON.stringify(fcmData))

        if (fcmRes.ok) {
          sent++
        } else {
          // Remove invalid tokens
          if (fcmData.error?.details?.[0]?.errorCode === 'UNREGISTERED') {
            await supabase.from('device_tokens').delete().eq('fcm_token', fcm_token)
          }
        }
      } catch (e) {
        console.error('FCM send error:', e)
      }
    }

    // Log the event
    await supabase.from('notification_events').insert({
      user_id,
      type,
      title,
      body,
      payload: data || {},
      status: sent > 0 ? 'sent' : 'failed'
    })

    return new Response(JSON.stringify({ sent }), {
      headers: { 'Content-Type': 'application/json' }
    })

  } catch (e) {
    console.error('Function error:', e)
    return new Response(JSON.stringify({ error: e.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    })
  }
})

async function getFirebaseToken(serviceAccount: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  
  const header = btoa(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')
  
  const payload = btoa(JSON.stringify({
    iss: serviceAccount.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600
  })).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')

  const signingInput = `${header}.${payload}`

  const pemKey = serviceAccount.private_key
  const pemContent = pemKey
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s/g, '')

  const binaryKey = Uint8Array.from(atob(pemContent), c => c.charCodeAt(0))

  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    binaryKey.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign']
  )

  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    cryptoKey,
    new TextEncoder().encode(signingInput)
  )

  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')

  const jwt = `${signingInput}.${sigB64}`

  const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`
  })

  const tokenData = await tokenRes.json()
  console.log('Token response:', JSON.stringify(tokenData))
  
  if (!tokenData.access_token) {
    throw new Error('Failed to get access token: ' + JSON.stringify(tokenData))
  }

  return tokenData.access_token
}