// /*
//  * This Source Code Form is subject to the terms of the Mozilla Public
//  * License, v. 2.0. If a copy of the MPL was not distributed with this
//  * file, You can obtain one at https://mozilla.org/MPL/2.0/.
//  *
//  * OpenCRVS is also distributed under the terms of the Civil Registration
//  * & Healthcare Disclaimer located at http://opencrvs.org/license.
//  *
//  * Copyright (C) The OpenCRVS Authors. OpenCRVS and the OpenCRVS
//  * graphic logo are (registered/a) trademark(s) of Plan International.
//  */

/// <reference types="Cypress" />

context('Certificate Integration Test', () => {
  beforeEach(() => {
    indexedDB.deleteDatabase('OpenCRVS')
  })

  it('Tests from declaration to certification using minimum input', () => {
    
    cy.declareDeclarationWithMinimumInput('AZ', 'Antor')
  
  })

  it('Registers Minimum input declaration',() => {
   
    cy.login('registrar')
      // CREATE PIN
    cy.createPin()
      //review declaration
    cy.reviewForm()

     //register Declaration
    cy.submitForm()
  })

  it('Prints minimum input declaration showing the pdf form',() => {
   
    cy.login('registrar')
    // CREATE PIN
    cy.createPin()
    cy.printDeclaration() 
  })
})
