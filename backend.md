# RenewIQ Backend API Reference

This document is the single source of truth for frontend integration.
It covers every currently exposed backend route, expected inputs, output structure, and failure behavior.

## 1. Base URL and General Rules

- Local base URL: `http://localhost:8000`
- Swagger docs: `GET /docs`
- ReDoc: `GET /redoc`
- API content type: `application/json`
- Twilio webhook content type: `application/x-www-form-urlencoded`
- SendGrid event webhook content type: `application/json`

## 2. Standard Response Contract

Core API routes (health, customers, policies, notifications, agent) are designed to follow this consistent envelope.

### Success shape

```json
{
  "success": true,
  "message": "Human readable success message",
  "data": {},
  "error": null
}
```

### Error shape

```json
{
  "success": false,
  "message": "Human readable error message",
  "data": null,
  "error": {
    "code": "ERROR_CODE",
    "details": {}
  }
}
```

## 3. Global Error Handling

### 3.1 Validation failure (422)

Happens when body/query/path params are invalid.

Example:

```json
{
  "success": false,
  "message": "Validation failed",
  "data": null,
  "error": {
    "code": "VALIDATION_ERROR",
    "details": {
      "path": "http://localhost:8000/policies/abc",
      "errors": [
        {
          "loc": ["path", "policy_id"],
          "msg": "Input should be a valid UUID",
          "type": "uuid_parsing"
        }
      ]
    }
  }
}
```

### 3.2 HTTPException (404, 409, etc.)

Example for not found:

```json
{
  "success": false,
  "message": "Policy not found",
  "data": null,
  "error": {
    "code": "HTTP_404",
    "details": {
      "path": "http://localhost:8000/policies/20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
      "detail": "Policy not found"
    }
  }
}
```

### 3.3 Unexpected server error (500)

```json
{
  "success": false,
  "message": "An unexpected error occurred. Our team has been notified.",
  "data": null,
  "error": {
    "code": "INTERNAL_SERVER_ERROR",
    "details": {
      "path": "http://localhost:8000/some/endpoint"
    }
  }
}
```

## 4. Health Routes

## 4.1 GET /

- Purpose: quick API liveness check.
- Request body: none
- Query params: none
- Path params: none

Success response (200):

```json
{
  "success": true,
  "message": "API is running",
  "data": {
    "status": "ok",
    "service": "RenewIQ Insurance Agent API"
  },
  "error": null
}
```

Possible failure conditions:
- Rare unexpected runtime issue resulting in 500.

Error response example:

```json
{
  "success": false,
  "message": "An unexpected error occurred. Our team has been notified.",
  "data": null,
  "error": {
    "code": "INTERNAL_SERVER_ERROR",
    "details": {
      "path": "http://localhost:8000/"
    }
  }
}
```

## 4.2 GET /health

- Purpose: checks DB connection, scheduler state, and OpenAI reachability.
- Request body: none
- Query params: none
- Path params: none

Success response example (healthy, 200):

```json
{
  "success": true,
  "message": "Health check completed",
  "data": {
    "status": "ok",
    "db": { "status": "ok" },
    "scheduler": { "status": "running" },
    "openai": { "status": "reachable" }
  },
  "error": null
}
```

Degraded response example (still 200):

```json
{
  "success": false,
  "message": "Service is degraded",
  "data": {
    "status": "degraded",
    "db": { "status": "error", "detail": "connection failed" },
    "scheduler": { "status": "stopped" },
    "openai": { "status": "unreachable", "detail": "timeout" }
  },
  "error": {
    "code": "SERVICE_DEGRADED",
    "details": {}
  }
}
```

Possible failure conditions:
- Unhandled internal error while generating health output.

## 5. Customers API

Base path: `/customers`

## 5.1 POST /customers/

- Purpose: create a new customer.
- Body required fields:
  - `first_name` (string)
  - `last_name` (string)
  - `phone` (string)
- Body optional fields:
  - `email` (email)
  - `whatsapp_number` (string)
  - `city` (string)
  - `state` (string)
  - `pincode` (string)
  - `customer_segment` (string, default `STANDARD`)
  - `preferred_language_id` (integer)
- Query params: none
- Path params: none

Request example:

```json
{
  "first_name": "Aarav",
  "last_name": "Sharma",
  "email": "aarav.sharma@example.com",
  "phone": "+919876543210",
  "whatsapp_number": "+919876543210",
  "city": "Mumbai",
  "state": "Maharashtra",
  "pincode": "400001",
  "customer_segment": "STANDARD",
  "preferred_language_id": 1
}
```

Success response (201):

```json
{
  "success": true,
  "message": "Customer created",
  "data": {
    "id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
    "il_customer_id": null,
    "first_name": "Aarav",
    "last_name": "Sharma",
    "full_name": "Aarav Sharma",
    "email": "aarav.sharma@example.com",
    "phone": "+919876543210",
    "whatsapp_number": "+919876543210",
    "city": "Mumbai",
    "state": "Maharashtra",
    "pincode": "400001",
    "customer_segment": "STANDARD",
    "kyc_status": "PENDING",
    "is_opted_out": false
  },
  "error": null
}
```

Error response example (duplicate phone, 409):

```json
{
  "success": false,
  "message": "A customer with this phone already exists.",
  "data": null,
  "error": {
    "code": "HTTP_409",
    "details": {
      "path": "http://localhost:8000/customers/",
      "detail": "A customer with this phone already exists."
    }
  }
}
```

Failure conditions:
- Phone already exists (409)
- Invalid input/body fields (422)

## 5.2 GET /customers/

- Purpose: list customers.
- Behavior note: returns only customers where `is_opted_out == false`.
- Request body: none
- Query params (all optional):
  - `skip` (int, default 0)
  - `limit` (int, default 100)
  - `segment` (string)
  - `city` (string)
- Path params: none

Success response (200):

```json
{
  "success": true,
  "message": "Customers fetched",
  "data": [
    {
      "id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
      "il_customer_id": null,
      "first_name": "Aarav",
      "last_name": "Sharma",
      "full_name": "Aarav Sharma",
      "email": "aarav.sharma@example.com",
      "phone": "+919876543210",
      "whatsapp_number": "+919876543210",
      "city": "Mumbai",
      "state": "Maharashtra",
      "pincode": "400001",
      "customer_segment": "STANDARD",
      "kyc_status": "PENDING",
      "is_opted_out": false
    }
  ],
  "error": null
}
```

Error response example (422):

```json
{
  "success": false,
  "message": "Validation failed",
  "data": null,
  "error": {
    "code": "VALIDATION_ERROR",
    "details": {
      "path": "http://localhost:8000/customers/?skip=abc",
      "errors": []
    }
  }
}
```

Failure conditions:
- Invalid query type/format (422)

## 5.3 GET /customers/{customer_id}

- Purpose: fetch single customer by UUID.
- Request body: none
- Query params: none
- Path params:
  - `customer_id` (UUID, required)

Success response (200):

```json
{
  "success": true,
  "message": "Customer fetched",
  "data": {
    "id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
    "first_name": "Aarav",
    "last_name": "Sharma",
    "full_name": "Aarav Sharma",
    "phone": "+919876543210",
    "email": "aarav.sharma@example.com",
    "kyc_status": "PENDING",
    "is_opted_out": false,
    "city": "Mumbai",
    "state": "Maharashtra",
    "pincode": "400001",
    "customer_segment": "STANDARD",
    "whatsapp_number": "+919876543210",
    "il_customer_id": null
  },
  "error": null
}
```

Error response example (404):

```json
{
  "success": false,
  "message": "Customer not found",
  "data": null,
  "error": {
    "code": "HTTP_404",
    "details": {
      "path": "http://localhost:8000/customers/8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
      "detail": "Customer not found"
    }
  }
}
```

Failure conditions:
- Customer does not exist (404)
- Invalid UUID format (422)

## 5.4 PUT /customers/{customer_id}

- Purpose: update customer fields.
- Request body: all fields optional (partial update)
  - `first_name`, `last_name`, `email`, `phone`, `whatsapp_number`
  - `city`, `state`, `pincode`, `customer_segment`, `is_opted_out`
- Query params: none
- Path params:
  - `customer_id` (UUID, required)

Request example:

```json
{
  "city": "Pune",
  "state": "Maharashtra",
  "is_opted_out": false
}
```

Success response (200):

```json
{
  "success": true,
  "message": "Customer updated",
  "data": {
    "id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
    "city": "Pune",
    "state": "Maharashtra",
    "is_opted_out": false
  },
  "error": null
}
```

Error response example (409 duplicate phone):

```json
{
  "success": false,
  "message": "A customer with this phone already exists.",
  "data": null,
  "error": {
    "code": "HTTP_409",
    "details": {
      "path": "http://localhost:8000/customers/8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
      "detail": "A customer with this phone already exists."
    }
  }
}
```

Failure conditions:
- Customer not found (404)
- Duplicate phone during update (409)
- Validation failure (422)

## 5.5 DELETE /customers/{customer_id}

- Purpose: permanently delete customer.
- Request body: none
- Query params: none
- Path params:
  - `customer_id` (UUID, required)

Success response (200):

```json
{
  "success": true,
  "message": "Customer deleted",
  "data": null,
  "error": null
}
```

Error response example (404):

```json
{
  "success": false,
  "message": "Customer not found",
  "data": null,
  "error": {
    "code": "HTTP_404",
    "details": {
      "path": "http://localhost:8000/customers/8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
      "detail": "Customer not found"
    }
  }
}
```

Failure conditions:
- Customer not found (404)
- Invalid UUID (422)

## 6. Policies API

Base path: `/policies`

## 6.1 POST /policies/

- Purpose: create a policy.
- Request body required:
  - `customer_id` (UUID)
  - `product_id` (int)
  - `branch_id` (int)
  - `il_policy_number` (string)
  - `policy_prefix` (string)
  - `risk_start_date` (date: YYYY-MM-DD)
  - `risk_end_date` (date: YYYY-MM-DD)
  - `sum_insured` (number)
  - `basic_premium` (number)
  - `net_premium` (number)
- Request body optional:
  - `issue_date` (date)
  - `payment_mode` (string, default `ANNUAL`)
  - `policy_status` (string, default `ACTIVE`)
- Query params: none
- Path params: none

Request example:

```json
{
  "customer_id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
  "product_id": 1,
  "branch_id": 101,
  "il_policy_number": "IL-2026-000001",
  "policy_prefix": "MOTOR",
  "risk_start_date": "2026-01-01",
  "risk_end_date": "2027-01-01",
  "sum_insured": 500000,
  "basic_premium": 12000,
  "net_premium": 14160,
  "payment_mode": "ANNUAL",
  "policy_status": "ACTIVE"
}
```

Success response (201):

```json
{
  "success": true,
  "message": "Policy created",
  "data": {
    "id": "20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
    "customer_id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
    "product_id": 1,
    "il_policy_number": "IL-2026-000001",
    "policy_prefix": "MOTOR",
    "risk_start_date": "2026-01-01",
    "risk_end_date": "2027-01-01",
    "issue_date": "2026-03-17",
    "expiry_date": null,
    "sum_insured": 500000,
    "basic_premium": 12000,
    "net_premium": 14160,
    "gst_amount": null,
    "total_premium": null,
    "payment_mode": "ANNUAL",
    "policy_status": "ACTIVE",
    "renewal_count": 0,
    "is_first_policy": true,
    "product_line": "MOTOR"
  },
  "error": null
}
```

Error response example (missing customer, 404):

```json
{
  "success": false,
  "message": "Customer not found",
  "data": null,
  "error": {
    "code": "HTTP_404",
    "details": {
      "path": "http://localhost:8000/policies/",
      "detail": "Customer not found"
    }
  }
}
```

Failure conditions:
- Customer does not exist (404)
- Product does not exist (404)
- Validation failure for fields (422)

## 6.2 GET /policies/

- Purpose: list policies with filters.
- Request body: none
- Query params (all optional):
  - `status` (string)
  - `customer_id` (UUID)
  - `product_line` (string)
  - `expiring_within_days` (int)
- Path params: none

Success response (200):

```json
{
  "success": true,
  "message": "Policies fetched",
  "data": [
    {
      "id": "20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
      "customer_id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
      "il_policy_number": "IL-2026-000001",
      "policy_status": "ACTIVE",
      "risk_end_date": "2027-01-01",
      "product_line": "MOTOR"
    }
  ],
  "error": null
}
```

Error response example (422 invalid UUID/query):

```json
{
  "success": false,
  "message": "Validation failed",
  "data": null,
  "error": {
    "code": "VALIDATION_ERROR",
    "details": {
      "path": "http://localhost:8000/policies/?customer_id=invalid",
      "errors": []
    }
  }
}
```

Failure conditions:
- Invalid query values/UUID/date (422)

## 6.3 GET /policies/{policy_id}

- Purpose: fetch one policy.
- Request body: none
- Query params: none
- Path params:
  - `policy_id` (UUID, required)

Success response (200):

```json
{
  "success": true,
  "message": "Policy fetched",
  "data": {
    "id": "20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
    "il_policy_number": "IL-2026-000001",
    "policy_status": "ACTIVE",
    "product_line": "MOTOR"
  },
  "error": null
}
```

Error response example (404):

```json
{
  "success": false,
  "message": "Policy not found",
  "data": null,
  "error": {
    "code": "HTTP_404",
    "details": {
      "path": "http://localhost:8000/policies/20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
      "detail": "Policy not found"
    }
  }
}
```

Failure conditions:
- Policy not found (404)
- Invalid UUID (422)

## 6.4 PUT /policies/{policy_id}

- Purpose: update selected policy fields.
- Request body optional fields:
  - `policy_status` (string)
  - `risk_end_date` (date)
  - `payment_mode` (string)
  - `net_premium` (number)
  - `sum_insured` (number)
- Query params: none
- Path params:
  - `policy_id` (UUID, required)

Request example:

```json
{
  "policy_status": "EXPIRING",
  "net_premium": 14999
}
```

Success response (200):

```json
{
  "success": true,
  "message": "Policy updated",
  "data": {
    "id": "20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
    "policy_status": "EXPIRING",
    "net_premium": 14999
  },
  "error": null
}
```

Error response example (404):

```json
{
  "success": false,
  "message": "Policy not found",
  "data": null,
  "error": {
    "code": "HTTP_404",
    "details": {
      "path": "http://localhost:8000/policies/20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
      "detail": "Policy not found"
    }
  }
}
```

Failure conditions:
- Policy not found (404)
- Invalid body/path (422)

## 6.5 PUT /policies/{policy_id}/mark-renewed

- Purpose: mark policy as renewed and increment `renewal_count`.
- Request body: none
- Query params: none
- Path params:
  - `policy_id` (UUID, required)

Success response (200):

```json
{
  "success": true,
  "message": "Policy marked as renewed",
  "data": {
    "id": "20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
    "policy_status": "RENEWED",
    "renewal_count": 1
  },
  "error": null
}
```

Error response example (404):

```json
{
  "success": false,
  "message": "Policy not found",
  "data": null,
  "error": {
    "code": "HTTP_404",
    "details": {
      "path": "http://localhost:8000/policies/20a4f3c7-0edf-4f97-94d0-f741d2a0f98b/mark-renewed",
      "detail": "Policy not found"
    }
  }
}
```

Failure conditions:
- Policy not found (404)
- Invalid UUID (422)

## 6.6 DELETE /policies/{policy_id}

- Purpose: soft cancel policy by setting `policy_status` to `CANCELLED`.
- Request body: none
- Query params: none
- Path params:
  - `policy_id` (UUID, required)

Success response (200):

```json
{
  "success": true,
  "message": "Policy cancelled",
  "data": null,
  "error": null
}
```

Error response example (404):

```json
{
  "success": false,
  "message": "Policy not found",
  "data": null,
  "error": {
    "code": "HTTP_404",
    "details": {
      "path": "http://localhost:8000/policies/20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
      "detail": "Policy not found"
    }
  }
}
```

Failure conditions:
- Policy not found (404)
- Invalid UUID (422)

## 7. Notifications API

Base path: `/notifications`

## 7.1 GET /notifications/history/{customer_id}

- Purpose: fetch notification/reminder history for one customer.
- Request body: none
- Query params:
  - `limit` (int, optional, default 50, max 200)
- Path params:
  - `customer_id` (UUID, required)

Success response (200):

```json
{
  "success": true,
  "message": "Notification history fetched",
  "data": [
    {
      "id": "cd97cab4-59af-4544-9a45-3e9f49068ef2",
      "policy_id": "20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
      "customer_id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
      "channel_code": "SMS",
      "reminder_window": "D-7",
      "attempt_number": 1,
      "is_fallback": false,
      "scheduled_at": "2026-03-17T10:00:00Z",
      "sent_at": "2026-03-17T10:00:05Z",
      "delivery_status": "DELIVERED",
      "link_clicked": true,
      "renewed_after_click": false,
      "agent_notes": "Intent: INTERESTED"
    }
  ],
  "error": null
}
```

Error response example (422):

```json
{
  "success": false,
  "message": "Validation failed",
  "data": null,
  "error": {
    "code": "VALIDATION_ERROR",
    "details": {
      "path": "http://localhost:8000/notifications/history/invalid-uuid",
      "errors": []
    }
  }
}
```

Failure conditions:
- Invalid UUID (422)
- Invalid limit value (422)

## 7.2 GET /notifications/pending

- Purpose: list active/expiring policies due within a time window.
- Request body: none
- Query params:
  - `within_days` (int, optional, default 30, min 1, max 90)
  - `product_line` (string, optional)
- Path params: none

Success response (200):

```json
{
  "success": true,
  "message": "Pending renewals fetched",
  "data": [
    {
      "customer_id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
      "customer_name": "Aarav Sharma",
      "email": "aarav.sharma@example.com",
      "phone": "+919876543210",
      "policy_id": "20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
      "il_policy_number": "IL-2026-000001",
      "product_line": "MOTOR",
      "expiry_date": "2026-04-10",
      "days_until_expiry": 24,
      "total_premium": 14160,
      "last_channel": "SMS",
      "last_notified_at": "2026-03-15T09:30:00Z",
      "notification_count": 2
    }
  ],
  "error": null
}
```

Error response example (422):

```json
{
  "success": false,
  "message": "Validation failed",
  "data": null,
  "error": {
    "code": "VALIDATION_ERROR",
    "details": {
      "path": "http://localhost:8000/notifications/pending?within_days=999",
      "errors": []
    }
  }
}
```

Failure conditions:
- `within_days` out of range (422)
- Invalid query format (422)

## 8. Agent API

Base path: `/agent`

## 8.1 POST /agent/trigger/{policy_id}

- Purpose: trigger background renewal agent run for a policy.
- Request body: none
- Query params: none
- Path params:
  - `policy_id` (UUID, required)

Success response (200, triggered):

```json
{
  "success": true,
  "message": "Agent triggered",
  "data": {
    "policy_id": "20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
    "customer_id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
    "status": "triggered",
    "message": "Agent triggered via sms."
  },
  "error": null
}
```

Success response (200, skipped):

```json
{
  "success": true,
  "message": "Agent skipped",
  "data": {
    "policy_id": "20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
    "customer_id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
    "status": "skipped",
    "message": "Policy is already renewed."
  },
  "error": null
}
```

Error response example (404):

```json
{
  "success": false,
  "message": "Policy not found",
  "data": null,
  "error": {
    "code": "HTTP_404",
    "details": {
      "path": "http://localhost:8000/agent/trigger/20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
      "detail": "Policy not found"
    }
  }
}
```

Failure conditions:
- Policy not found (404)
- Linked customer not found (404)
- Background task can fail after response is sent (response still may be success)

## 8.2 GET /agent/status/{policy_id}

- Purpose: fetch current policy + notification status snapshot used by the agent flow.
- Request body: none
- Query params: none
- Path params:
  - `policy_id` (UUID, required)

Success response (200):

```json
{
  "success": true,
  "message": "Agent status fetched",
  "data": {
    "policy_id": "20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
    "il_policy_number": "IL-2026-000001",
    "policy_status": "EXPIRING",
    "product_line": "MOTOR",
    "expiry_date": "2026-04-10",
    "days_until_expiry": 24,
    "customer_id": "8f1d7bde-3b1a-4eb1-8ab7-0a4de5e4d3f7",
    "customer_name": "Aarav Sharma",
    "total_notifications_sent": 2,
    "last_channel": "SMS",
    "last_sent_at": "2026-03-15T09:30:00Z",
    "last_delivery_status": "READ",
    "link_clicked": true,
    "is_renewed": false
  },
  "error": null
}
```

Error response example (404):

```json
{
  "success": false,
  "message": "Policy not found",
  "data": null,
  "error": {
    "code": "HTTP_404",
    "details": {
      "path": "http://localhost:8000/agent/status/20a4f3c7-0edf-4f97-94d0-f741d2a0f98b",
      "detail": "Policy not found"
    }
  }
}
```

Failure conditions:
- Policy not found (404)
- Linked customer not found (404)
- Invalid UUID (422)

## 9. Webhook Routes

Base path: `/webhooks`

Important: these are provider callback endpoints, not frontend user-action APIs.
Some webhook success responses are intentionally XML/plain for Twilio compatibility.
Errors still follow the global JSON error envelope when exceptions are raised.

## 9.1 POST /webhooks/sms

- Purpose: receive inbound SMS from Twilio and classify intent.
- Request body format: form-data (`application/x-www-form-urlencoded`)
- Required form fields:
  - `From`
  - `Body`
- Optional form fields:
  - `MessageSid`
  - `NumMedia`
- Required header:
  - `X-Twilio-Signature`

Twilio-compatible success response (actual, 200):
- XML body (TwiML), may be empty or contain a reply message.

Frontend-normalized success example:

```json
{
  "success": true,
  "message": "SMS webhook processed",
  "data": {
    "provider": "twilio",
    "channel": "SMS",
    "intent": "RENEWED",
    "customerMatched": true
  },
  "error": null
}
```

Error response example (invalid signature, 403):

```json
{
  "success": false,
  "message": "Invalid Twilio signature",
  "data": null,
  "error": {
    "code": "HTTP_403",
    "details": {
      "path": "http://localhost:8000/webhooks/sms",
      "detail": "Invalid Twilio signature"
    }
  }
}
```

Failure conditions:
- Invalid/missing Twilio signature (403)
- Required form fields missing (422)

## 9.2 POST /webhooks/whatsapp

- Purpose: receive inbound WhatsApp messages from Twilio and classify intent.
- Request body format: form-data
- Required form fields:
  - `From`
  - `Body`
- Optional form fields:
  - `MessageSid`
  - `ProfileName`
- Required header:
  - `X-Twilio-Signature`

Twilio-compatible success response (actual, 200):
- XML body (TwiML), may contain informational reply for selected intents.

Frontend-normalized success example:

```json
{
  "success": true,
  "message": "WhatsApp webhook processed",
  "data": {
    "provider": "twilio",
    "channel": "WHATSAPP",
    "intent": "NEEDS_INFO",
    "customerMatched": true
  },
  "error": null
}
```

Error response example (invalid signature, 403):

```json
{
  "success": false,
  "message": "Invalid Twilio WhatsApp signature",
  "data": null,
  "error": {
    "code": "HTTP_403",
    "details": {
      "path": "http://localhost:8000/webhooks/whatsapp",
      "detail": "Invalid Twilio WhatsApp signature"
    }
  }
}
```

Failure conditions:
- Invalid/missing Twilio signature (403)
- Missing required form fields (422)

## 9.3 POST /webhooks/email

- Purpose: process inbound email replies (SendGrid inbound parse).
- Request body format: form-data
- Expected form fields:
  - `from` (preferred, used to identify sender)
  - `subject` (optional)
  - `text` (optional)
  - `html` (optional)
  - `envelope` (optional)

Actual success responses (200):

```json
{ "status": "ok", "intent": "RENEWED" }
```

or

```json
{ "status": "ignored", "reason": "customer not found" }
```

Frontend-normalized success example:

```json
{
  "success": true,
  "message": "Inbound email processed",
  "data": {
    "status": "ok",
    "intent": "RENEWED"
  },
  "error": null
}
```

Frontend-normalized ignored example:

```json
{
  "success": true,
  "message": "Inbound email ignored",
  "data": {
    "status": "ignored",
    "reason": "customer not found"
  },
  "error": null
}
```

Error response example (500):

```json
{
  "success": false,
  "message": "An unexpected error occurred. Our team has been notified.",
  "data": null,
  "error": {
    "code": "INTERNAL_SERVER_ERROR",
    "details": {
      "path": "http://localhost:8000/webhooks/email"
    }
  }
}
```

Failure conditions:
- Unexpected processing failures (500)

## 9.4 POST /webhooks/email/event

- Purpose: process SendGrid email events (delivered, open, click, bounce, etc.).
- Request body format: JSON array
- Required/used headers:
  - `X-Twilio-Email-Event-Webhook-Signature` (required if signing key is configured)
  - `X-Twilio-Email-Event-Webhook-Timestamp` (required if signing key is configured)

Request example:

```json
[
  {
    "event": "click",
    "email": "aarav.sharma@example.com",
    "url": "https://rnwq.in/abcd1234"
  }
]
```

Actual success response (200):

```json
{
  "status": "ok",
  "events_processed": 1
}
```

Frontend-normalized success example:

```json
{
  "success": true,
  "message": "Email event webhook processed",
  "data": {
    "status": "ok",
    "events_processed": 1
  },
  "error": null
}
```

Error response example (invalid JSON, 400):

```json
{
  "success": false,
  "message": "Invalid JSON payload",
  "data": null,
  "error": {
    "code": "HTTP_400",
    "details": {
      "path": "http://localhost:8000/webhooks/email/event",
      "detail": "Invalid JSON payload"
    }
  }
}
```

Error response example (invalid signature, 403):

```json
{
  "success": false,
  "message": "Invalid SendGrid event webhook signature",
  "data": null,
  "error": {
    "code": "HTTP_403",
    "details": {
      "path": "http://localhost:8000/webhooks/email/event",
      "detail": "Invalid SendGrid event webhook signature"
    }
  }
}
```

Failure conditions:
- Invalid signature when signature verification is active (403)
- Invalid JSON payload (400)

## 9.5 POST /webhooks/call-status

- Purpose: process Twilio voice callback statuses and update reminder delivery state.
- Request body format: form-data
- Required form fields:
  - `CallSid`
  - `CallStatus`
- Optional form fields:
  - `To`, `From`, `Duration`, `AnsweredBy`
- Required header:
  - `X-Twilio-Signature`

Twilio-compatible success response (actual, 200):
- Empty plain/XML response body.

Frontend-normalized success example:

```json
{
  "success": true,
  "message": "Call status processed",
  "data": {
    "provider": "twilio",
    "channel": "VOICE",
    "callSid": "CA123456789",
    "callStatus": "completed",
    "deliveryStatus": "DELIVERED"
  },
  "error": null
}
```

Error response example (invalid signature, 403):

```json
{
  "success": false,
  "message": "Invalid Twilio call webhook signature",
  "data": null,
  "error": {
    "code": "HTTP_403",
    "details": {
      "path": "http://localhost:8000/webhooks/call-status",
      "detail": "Invalid Twilio call webhook signature"
    }
  }
}
```

Failure conditions:
- Invalid/missing Twilio signature (403)
- Missing required form fields (422)

## 10. Complete Endpoint List

- `GET /`
- `GET /health`
- `POST /customers/`
- `GET /customers/`
- `GET /customers/{customer_id}`
- `PUT /customers/{customer_id}`
- `DELETE /customers/{customer_id}`
- `POST /policies/`
- `GET /policies/`
- `GET /policies/{policy_id}`
- `PUT /policies/{policy_id}`
- `PUT /policies/{policy_id}/mark-renewed`
- `DELETE /policies/{policy_id}`
- `GET /notifications/history/{customer_id}`
- `GET /notifications/pending`
- `POST /agent/trigger/{policy_id}`
- `GET /agent/status/{policy_id}`
- `POST /webhooks/sms`
- `POST /webhooks/whatsapp`
- `POST /webhooks/email`
- `POST /webhooks/email/event`
- `POST /webhooks/call-status`

## 11. Frontend Integration Notes

- For non-webhook APIs, you can directly rely on the standard envelope.
- For webhook APIs, success output may be XML or custom JSON by design; if needed, normalize in the frontend API client layer before use.
- Always handle:
  - `success = false` envelope errors
  - HTTP 422 validation errors
  - 404 and 409 business errors
- Recommended client flow:
  1. Check HTTP status
  2. Parse JSON/XML based on endpoint type
  3. Map to frontend-standard model
  4. Show `message` to user and use `error.code` for logic branches
