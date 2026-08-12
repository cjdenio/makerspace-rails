# Public Rental Spots

## Purpose and canonical route

`GET /api/rental_spots/:id/public` is an unauthenticated JSON API that returns
public catalog information for one rental spot. It is intended to back QR-code
and deep-link landing experiences, including clients that prompt a visitor to
sign in before taking further action. It is **not** a server-rendered
`/rental_spots/` page.

## Identifiers

`:id` accepts either:

- the rental spot's Mongo ObjectID; or
- its exact, case-sensitive, human-readable `RentalSpot#number`.

Path segments must be URL encoded. For example, the representative spot number
`LR-Tote-1` is encoded as follows (the hyphens require no escaping):

```text
GET /api/rental_spots/LR-Tote-1/public
```

A value containing spaces or other reserved characters must be percent encoded
before it is placed in the path. For operational QR codes, prefer a stable,
human-readable spot number when appropriate. It is recognizable to staff and
avoids exposing a database identifier; however, a renamed or reused number
changes what the link resolves to.

## Authentication and format

No member session or token is required. The `/api` route defaults to JSON and
has no HTML representation.

## Public response

A successful response contains only the fields selected by the public
serializer:

| Field | Meaning |
| --- | --- |
| `id` | Mongo ObjectID. |
| `number` | Human-readable rental spot number. |
| `location` | Display location. |
| `description` | Public description. |
| `rental_type_display_name` | Display name of the related rental type, or `null`. |
| `requires_approval` | Whether approval is required. |
| `active` | Current active flag. |
| `available` | Availability calculated at request time. |
| `invoice_option_name` | Related invoice option name, or `null`. |
| `invoice_option_amount` | Related invoice option amount, or `null`. |

The lookup intentionally does not filter on `active`, so an inactive spot
remains retrievable and reports `active: false`. Consumers must present that
state clearly. Likewise, `available` is a point-in-time informational value,
**not a reservation guarantee**; availability can change before a later rental
or reservation action succeeds.

If neither an ObjectID nor an exact spot number resolves, the lookup raises the
application's normal Mongoid document-not-found response (`404 Not Found`).

## Examples and QR guidance

A durable human-readable deep link:

```text
https://portal.example.org/api/rental_spots/LR-Tote-1/public
```

A database-ID link:

```text
https://portal.example.org/api/rental_spots/507f1f77bcf86cd799439011/public
```

Generate QR codes from the complete HTTPS URL for the deployed portal. Encode
the spot number as one URL path segment, test the printed code against the
production hostname, and make the client resilient to `404`, inactive spots,
and changes in `available`. Adding fields to the public serializer expands the
unauthenticated data contract and should receive a privacy review.
