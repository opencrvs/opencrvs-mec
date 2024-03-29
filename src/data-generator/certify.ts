import fetch from 'node-fetch'
import { User } from './users'

import { idsToFHIRIds, log, removeEmptyFields } from './util'
import {
  AttachmentInput,
  BirthRegistrationInput,
  DeathRegistrationInput,
  LocationType,
  MarkBirthAsCertifiedMutation,
  MarkDeathAsCertifiedMutation,
  PaymentOutcomeType,
  PaymentType
} from './gateway'
import { omit } from 'lodash'
import { GATEWAY_GQL_HOST } from './constants'
import { MARK_BIRTH_AS_CERTIFIED, MARK_DEATH_AS_CERTIFIED } from './queries'
import { differenceInDays } from 'date-fns'
import { ConfigResponse } from './config'
import { fetchDeathRegistration, fetchRegistration } from './declare'

export function createBirthCertificationDetails(
  createdAt: Date,
  declaration: Awaited<ReturnType<typeof fetchRegistration>>,
  config: ConfigResponse
) {
  const withIdsRemoved = idsToFHIRIds(
    omit(declaration, ['__typename', 'id', 'registration.type']),
    [
      'id',
      'eventLocation.id',
      'mother.id',
      'father.id',
      'child.id',
      'registration.id',
      'informant.individual.id',
      'informant.id'
    ]
  )
  delete withIdsRemoved.history

  const data = {
    ...withIdsRemoved,
    eventLocation: {
      _fhirID: withIdsRemoved.eventLocation?._fhirID
    },
    registration: {
      ...withIdsRemoved.registration,
      attachments: withIdsRemoved.registration?.attachments?.filter(
        (x): x is AttachmentInput => x !== null
      ),
      status: [
        {
          timestamp: createdAt.toISOString()
        }
      ],
      certificates: [
        {
          hasShowedVerifiedDocument: false,
          data: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
          collector: {
            relationship: 'MOTHER'
          }
        }
      ]
    }
  }
  return removeEmptyFields(data)
}

export function createDeathCertificationDetails(
  createdAt: Date,
  declaration: Awaited<ReturnType<typeof fetchDeathRegistration>>,
  config: ConfigResponse
): DeathRegistrationInput {
  const withIdsRemoved = idsToFHIRIds(
    omit(declaration, ['__typename', 'id', 'registration.type']),
    [
      'id',
      'eventLocation.id',
      'mother.id',
      'father.id',
      'informant.individual.id',
      'informant.id',
      'deceased.id',
      'registration.id'
    ]
  )

  const completionDays = differenceInDays(
    createdAt,
    declaration.deceased?.deceased?.deathDate
      ? new Date(declaration.deceased?.deceased?.deathDate)
      : new Date()
  )

  const paymentAmount =
    completionDays < config.config.DEATH.REGISTRATION_TARGET
      ? config.config.DEATH.FEE.ON_TIME
      : config.config.DEATH.FEE.DELAYED

  log(
    'Collecting certification payment of',
    paymentAmount,
    'for completion days',
    completionDays
  )

  const data: DeathRegistrationInput = {
    ...withIdsRemoved,
    deceased: {
      ...withIdsRemoved.deceased,
      identifier: withIdsRemoved.deceased?.identifier?.filter(
        (id) => id?.type != 'DEATH_REGISTRATION_NUMBER'
      )
    },
    eventLocation:
      withIdsRemoved.eventLocation?.type === LocationType.PrivateHome
        ? {
            address: withIdsRemoved.eventLocation.address,
            type: withIdsRemoved.eventLocation.type
          }
        : {
            _fhirID: withIdsRemoved.eventLocation?._fhirID
          },
    registration: {
      ...withIdsRemoved.registration,
      attachments: withIdsRemoved.registration?.attachments?.filter(
        (x): x is AttachmentInput => x !== null
      ),
      draftId: withIdsRemoved._fhirIDMap?.composition,
      certificates: [
        {
          hasShowedVerifiedDocument: false,
          data: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
          payments: [
            {
              type: PaymentType.Manual,
              total: paymentAmount,
              amount: paymentAmount,
              outcome: PaymentOutcomeType.Completed,
              date: createdAt
            }
          ],
          collector: {
            relationship: 'INFORMANT'
          }
        }
      ],
      status: [
        {
          timestamp: createdAt.toISOString(),
          timeLoggedMS: Math.round(9999 * Math.random())
        }
      ]
    }
  }

  return removeEmptyFields(data)
}

export async function markBirthAsCertified(
  id: string,
  user: User,
  details: BirthRegistrationInput
) {
  const { token, username } = user

  const requestStart = Date.now()

  const certifyDeclarationRes = await fetch(GATEWAY_GQL_HOST, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
      'x-correlation-id': `certification-${id}`
    },
    body: JSON.stringify({
      query: MARK_BIRTH_AS_CERTIFIED,
      variables: {
        id: id,
        details
      }
    })
  })
  const requestEnd = Date.now()
  const result = (await certifyDeclarationRes.json()) as {
    errors: any[]
    data: MarkBirthAsCertifiedMutation
  }

  if (result.errors) {
    console.error(JSON.stringify(result.errors, null, 2))
    throw new Error('Birth declaration could not be certified')
  }

  log(
    'Birth declaration',
    result.data.markBirthAsCertified,
    'is now certified by',
    username,
    `(took ${requestEnd - requestStart}ms)`
  )

  return result.data.markBirthAsCertified
}

export async function markDeathAsCertified(
  id: string,
  user: User,
  details: DeathRegistrationInput
) {
  const { token, username } = user

  const requestStart = Date.now()

  const certifyDeclarationRes = await fetch(GATEWAY_GQL_HOST, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
      'x-correlation-id': `death-certification-${id}`
    },
    body: JSON.stringify({
      query: MARK_DEATH_AS_CERTIFIED,
      variables: {
        id,
        details
      }
    })
  })
  const requestEnd = Date.now()
  const result = (await certifyDeclarationRes.json()) as {
    errors: any[]
    data: MarkDeathAsCertifiedMutation
  }
  if (result.errors) {
    console.error(JSON.stringify(result.errors, null, 2))
    details.registration?.certificates?.forEach((cert) => {
      if (cert?.data) {
        cert.data = 'REDACTED'
      }
    })
    console.error(JSON.stringify(details))
    throw new Error('Death declaration could not be certified')
  }

  log(
    'Death declaration',
    result.data.markDeathAsCertified,
    'is now certified by',
    username,
    `(took ${requestEnd - requestStart}ms)`
  )

  return result.data.markDeathAsCertified
}
