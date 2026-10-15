# Exact MemberSerializer projection used by Home (no viewer/provisioning options).
module HomeApiSchemas
  object = ->(properties) {
    { type: :object, properties: properties, required: properties.keys, additionalProperties: false }
  }
  string = { type: :string }
  nullable_string = { type: :string, nullable: true }
  boolean = { type: :boolean }
  nullable_timestamp = { type: :string, format: :'date-time', nullable: true }
  ids = { type: :array, items: string }
  household_role = { type: :string, enum: %w[primary secondary], nullable: true }

  SCHEMAS = {
    HomeMember: object.call({
      id: string,
      firstname: string,
      lastname: string,
      email: string,
      status: { '$ref' => '#/components/schemas/MemberStatus' },
      role: { '$ref' => '#/components/schemas/MemberRole' },
      expirationTime: { type: :integer, format: :int64, nullable: true, description: 'Unix time in milliseconds.' },
      memberContractSignedDate: { type: :string, format: :date, nullable: true },
      memberContractOnFile: boolean,
      totpEnabled: boolean,
      notes: nullable_string,
      household: object.call({
        groupName: nullable_string,
        displayName: string,
        role: household_role,
        primaryMemberName: nullable_string,
        memberCount: { type: :integer }
      }).merge(nullable: true),
      mailtrap: object.call({
        id: nullable_string,
        timestamp: nullable_timestamp,
        email: string,
        status: nullable_string,
        value: nullable_string
      }).merge(description: 'Latest delivery status for the current email, or an unknown status with null ID/timestamp when no event exists.'),
      slack: object.call({
        slackId: nullable_string,
        name: nullable_string,
        url: { type: :string, nullable: true, enum: [nil], description: 'Always null on Home to avoid Slack API calls. Use the top-level slack.newMembersChannelUrl.' }
      }).merge(nullable: true, description: 'Linked Slack identity, or null when none exists. Identity presence alone does not confirm invitation acceptance.'),
      checkoutApproverShopIds: ids,
      checkoutApproverToolIds: ids,
      resourceManagerShopIds: ids,
      isCheckoutApprover: boolean,
      slackManualDeactivationRequired: boolean,
      firebaseUid: nullable_string,
      mergedAt: nullable_timestamp,
      paidPendingStart: boolean,
      startDate: nullable_timestamp,
      cardId: nullable_string,
      subscription: boolean,
      subscriptionId: nullable_string,
      subscriptionPlanId: nullable_string,
      earnedMembershipId: nullable_string,
      earnedMembershipActive: boolean,
      customerId: nullable_string,
      address: object.call({
        street: nullable_string,
        unit: nullable_string,
        city: nullable_string,
        state: nullable_string,
        postalCode: nullable_string
      }),
      phone: nullable_string,
      silenceEmails: { type: :boolean, nullable: true },
      groupName: nullable_string,
      householdRole: household_role
    }).merge(description: 'Complete current-member representation returned by Home. Privileged provisioning and optional expiring-payment-card fields are not requested by this endpoint.'),
    HomeUnauthorized: {
      oneOf: [
        object.call({
          status: { type: :integer, enum: [401] },
          error: { type: :string, enum: ['unauthorized'] },
          message: string
        }).merge(title: 'AuthenticationRequired', description: 'No valid member session, including expired sessions or expired TOTP challenges.'),
        object.call({
          error: { type: :string, enum: ['TOTP verification required.'] }
        }).merge(title: 'TotpVerificationRequired', description: 'The signed-in member must complete the pending TOTP challenge.')
      ]
    }
  }.freeze
end
