/*
 * Copyright (c) 2020, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

import Foundation
import PsiApi
import AppStoreIAP
import PsiCashClient
import Utilities

enum PsiCashViewAction: Equatable {

    case switchTabs(PsiCashScreenTab)
    
    /// Initiates process of purchasing `product`.
    case purchaseTapped(product: AppStoreProduct)
    
    /// Cancels purchase confirmation (if any).
    case purchaseAccountConfirmationDismissed
    
    case signupOrLoginTapped

    case presentPsiCashAccountScreen(animated: Bool = true)

    case dismissedPsiCashAccountScreen
    
    case continuePurchaseWithoutAccountTapped
    
    case psiCashAccountDidChange
}

@objc enum PsiCashScreenTab: Int, TabControlViewTabType {
    case addPsiCash
    case speedBoost

    var localizedUserDescription: String {
        switch self {
        case .addPsiCash: return UserStrings.Add_psiCash()
        case .speedBoost: return UserStrings.Speed_boost()
        }
    }
}

struct PsiCashViewState: Equatable {

    /// Represents purchasing states, before actual purchase request is made.
    enum PurchaseRequestStateValues: Equatable {
        /// There are no purchase requests.
        case none
        /// Purchase request is pending user confirming whether they would like
        /// to make the purchase with, or without a PsiCash account.
        case confirmAccountLogin(AppStoreProduct)
    }

    var psiCashIAPPurchaseRequestState: PurchaseRequestStateValues

    var activeTab: PsiCashScreenTab

    /// Whether PsiCashAccountViewController should be displayed or not.
    var isPsiCashAccountScreenShown: Bool
}

struct PsiCashViewReducerState: Equatable {
    var viewState: PsiCashViewState
    let psiCashAccountType: PsiCashAccountType?
    let vpnStatus: TunnelProviderVPNStatus
}

struct PsiCashViewEnvironment {
    let feedbackLogger: FeedbackLogger
    let iapStore: (IAPAction) -> Effect<Never>
    let mainViewStore: (MainViewAction) -> Effect<Never>

    let getTopPresentedViewController: () -> UIViewController

    /// Makes `PsiCashAccountViewController` as root of UINavigationController.
    let makePsiCashAccountViewController: () -> UIViewController
    
    let dateCompare: DateCompare
}

let psiCashViewReducer = Reducer<PsiCashViewReducerState,
                                 PsiCashViewAction,
                                 PsiCashViewEnvironment> {
    state, action, environment in
    
    switch action {
    case .switchTabs(let newTab):
        // Mutates `activeTab` only if the value has changed.
        guard state.viewState.activeTab != newTab else {
            return []
        }
        state.viewState.activeTab = newTab
        return []

    case .purchaseTapped(product: let product):

        // Checks if there is already a purchase in progress.
        guard case .none = state.viewState.psiCashIAPPurchaseRequestState else {
            return []
        }

        guard case .psiCash = product.type else {
            return []
        }
        
        // If not logged into a PsiCash account, the user is first asked
        // to confirm whether they would like to make an account,
        // or continue the purchase without an account.
        switch state.psiCashAccountType {
        case .none:
            // Illegal state.
            environment.feedbackLogger.fatalError("PsiCash lib not initialized")
            return []
            
        case .noTokens:
            return [
                environment.feedbackLogger.log(
                    .error, "not allowed to make a purchase without PsiCash tokens").mapNever()
            ]

        case .account(loggedIn: true):
            state.viewState.psiCashIAPPurchaseRequestState = .none
            return [
                environment.iapStore(.purchase(product: product, resultPromise: nil)).mapNever()
            ]
            
        case .tracker,
             .account(loggedIn: false):

            state.viewState.psiCashIAPPurchaseRequestState = .confirmAccountLogin(product)

            return [
                
                Effect { observer, _ in

                    let topVC = environment.getTopPresentedViewController()

                    let vc = ViewBuilderViewController(
                        viewBuilder: PsiCashPurchasingConfirmViewBuilder(
                            closeButtonHandler: { [observer] in
                                observer.send(value: .purchaseAccountConfirmationDismissed)
                            },
                            signUpButtonHandler: { [observer] in
                                observer.send(value: .signupOrLoginTapped)
                            },
                            continueWithoutAccountHandler: { [observer] in
                                observer.send(value: .continuePurchaseWithoutAccountTapped)
                            }
                        ),
                        modalPresentationStyle: .overFullScreen,
                        onDismissed: { [observer] in
                            // Sends 'onCompleted' event.
                            // Note: This effect will never complete if onDismissed
                            // is never called.
                            observer.fulfill(value: .purchaseAccountConfirmationDismissed)
                        }
                    )

                    vc.modalTransitionStyle = .crossDissolve

                    topVC.safePresent(vc,
                                      animated: true,
                                      viewDidAppearHandler: nil)

                }
            ]
        }
        
    case .purchaseAccountConfirmationDismissed:
        guard case .confirmAccountLogin(_) = state.viewState.psiCashIAPPurchaseRequestState else {
            return []
        }
        state.viewState.psiCashIAPPurchaseRequestState = .none

        // Dismisses presented PsiCashPurchasingConfirmViewBuilder.
        return [
            .fireAndForget {
                let topVC = environment.getTopPresentedViewController()
                let searchResult = topVC.traversePresentingStackFor(
                    type: ViewBuilderViewController<PsiCashPurchasingConfirmViewBuilder>.self)

                switch searchResult {
                case .notPresent:
                    // No-op.
                    break
                case .presentInStack(let viewController):
                    viewController.dismiss(animated: false, completion: nil)

                case .presentTopOfStack(let viewController):
                    viewController.dismiss(animated: false, completion: nil)
                }
            }
        ]
        
    case .signupOrLoginTapped:
        
        guard state.viewState.isPsiCashAccountScreenShown == false else {
            return []
        }
        
        // Skips presenting PsiCash Account screen if tunnel is not connected.
        // Note that this is a quick check for informing the user,
        // and PsiCash Account screen performs it's own last second tunnel checks
        // before making any API requests.
        guard case .connected = state.vpnStatus else {

            // Informs user that tunnel is not connected.
            let alertEvent = AlertEvent(
                .psiCashAccountAlert(.tunnelNotConnectedAlert),
                date: environment.dateCompare.getCurrentTime()
            )
            
            return [
                environment.mainViewStore(.presentAlert(alertEvent)).mapNever()
            ]
            
        }

        if case .confirmAccountLogin(_) = state.viewState.psiCashIAPPurchaseRequestState {

            return [
                Effect { observer, _ in
                    let topVC = environment.getTopPresentedViewController()
                    let searchResult = topVC.traversePresentingStackFor(
                        type: ViewBuilderViewController<PsiCashPurchasingConfirmViewBuilder>.self)

                    switch searchResult {
                    case .notPresent:
                        // No-op.
                        observer.sendCompleted()
                        return

                    case .presentInStack(let viewController):
                        viewController.dismiss(animated: false, completion: {
                            observer.send(value: .presentPsiCashAccountScreen())
                            observer.sendCompleted()
                        })

                    case .presentTopOfStack(let viewController):
                        viewController.dismiss(animated: false, completion: {
                            observer.send(value: .presentPsiCashAccountScreen())
                            observer.sendCompleted()
                        })
                    }
                }
            ]
        } else {
            return [ Effect(value: .presentPsiCashAccountScreen()) ]
        }


    case .presentPsiCashAccountScreen(let animated):

        // Presents PsiCash Account screen if not already shown.
        guard state.viewState.isPsiCashAccountScreenShown == false else {
            return []
        }
        
        // Skips presenting PsiCash Account screen if tunnel is not connected.
        // Note that this is a quick check for informing the user,
        // and PsiCash Account screen performs it's own last second tunnel checks
        // before making any API requests.
        //
        // Note this this check is independent of the check performed when
        // handling other actions such as `.signupOrLoginTapped`.
        guard case .connected = state.vpnStatus else {

            // Informs user that tunnel is not connected.
            let alertEvent = AlertEvent(
                .psiCashAccountAlert(.tunnelNotConnectedAlert),
                date: environment.dateCompare.getCurrentTime()
            )
            
            return [
                environment.mainViewStore(.presentAlert(alertEvent)).mapNever()
            ]
            
        }

        state.viewState.isPsiCashAccountScreenShown = true

        return [
            .fireAndForget {
                let topVC = environment.getTopPresentedViewController()
                let searchResult = topVC.traversePresentingStackFor(
                    type: PsiCashAccountViewController.self, searchChildren: true)

                switch searchResult {
                case .notPresent:
                    let accountsViewController = environment.makePsiCashAccountViewController()
                    topVC.safePresent(accountsViewController,
                                      animated: animated,
                                      viewDidAppearHandler: nil)

                case .presentInStack(_),
                     .presentTopOfStack(_):
                    // No-op.
                    return
                }
            }
        ]

    case .dismissedPsiCashAccountScreen:
        guard state.viewState.isPsiCashAccountScreenShown == true else {
            return []
        }

        state.viewState.isPsiCashAccountScreenShown = false

        // If in a `.confirmAccountLogin` state after a the PsiCahAccountScreen
        // has been dismissed, and the user has logged in, then continues the purchase
        // since the PsiCash accounts screen has been dismisesd.
        // Otherwise, resets `viewState.psiCashIAPPurchasingState`.
        if case .confirmAccountLogin(let product) = state.viewState.psiCashIAPPurchaseRequestState {

            if case .account(loggedIn: true) = state.psiCashAccountType {
                state.viewState.psiCashIAPPurchaseRequestState = .none
                return [
                    environment.iapStore(.purchase(product: product, resultPromise: nil)).mapNever()
                ]
            } else {
                // User did not login. Cancels purchase request.
                state.viewState.psiCashIAPPurchaseRequestState = .none
            }
        }

        return []

    case .continuePurchaseWithoutAccountTapped:
        guard
            case .confirmAccountLogin(let product) = state.viewState.psiCashIAPPurchaseRequestState
        else {
            return []
        }
        
        state.viewState.psiCashIAPPurchaseRequestState = .none
        
        return [
            environment.iapStore(.purchase(product: product, resultPromise: nil)).mapNever(),

            // Dismisses purchase confirm screen.
            .fireAndForget {
                let topVC = environment.getTopPresentedViewController()
                let searchResult = topVC.traversePresentingStackFor(
                    type: ViewBuilderViewController<PsiCashPurchasingConfirmViewBuilder>.self)

                switch searchResult {
                case .notPresent:
                    // No-op.
                    return

                case .presentInStack(let viewController):
                    viewController.dismiss(animated: false, completion: nil)

                case .presentTopOfStack(let viewController):
                    viewController.dismiss(animated: false, completion: nil)
                }
            }
        ]

    case .psiCashAccountDidChange:
        guard case .account(loggedIn: true) = state.psiCashAccountType else {
            return []
        }
        
        state.viewState.isPsiCashAccountScreenShown = false
        
        guard
            case .confirmAccountLogin(let product) = state.viewState.psiCashIAPPurchaseRequestState
        else {
            return []
        }

        state.viewState.psiCashIAPPurchaseRequestState = .none
        
        return [
            environment.iapStore(.purchase(product: product, resultPromise: nil)).mapNever()
        ]
    }
    
}
