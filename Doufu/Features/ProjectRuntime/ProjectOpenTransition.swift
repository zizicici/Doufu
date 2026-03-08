//
//  ProjectOpenTransition.swift
//  Doufu
//
//  Custom full-screen present/dismiss transition that expands a card cell
//  into the workspace and collapses it back on dismiss.
//

import UIKit

// MARK: - Transitioning Delegate

final class ProjectOpenTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {

    /// Frame of the source cell in the window's coordinate space.
    var originFrame: CGRect = .zero

    /// Corner radius of the source cell.
    var originCornerRadius: CGFloat = 14

    /// Interactive dismiss controller — set by the presented VC.
    var interactionController: ProjectDismissInteractionController?

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        ProjectOpenAnimator(originFrame: originFrame, originCornerRadius: originCornerRadius, isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        ProjectOpenAnimator(originFrame: originFrame, originCornerRadius: originCornerRadius, isPresenting: false)
    }

    func interactionControllerForDismissal(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        guard let controller = interactionController, controller.isInteractive else {
            return nil
        }
        return controller
    }
}

// MARK: - Animator

private final class ProjectOpenAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    let originFrame: CGRect
    let originCornerRadius: CGFloat
    let isPresenting: Bool

    private let duration: TimeInterval = 0.42
    private let springDamping: CGFloat = 0.88

    init(originFrame: CGRect, originCornerRadius: CGFloat, isPresenting: Bool) {
        self.originFrame = originFrame
        self.originCornerRadius = originCornerRadius
        self.isPresenting = isPresenting
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        duration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        if isPresenting {
            animatePresent(using: transitionContext)
        } else {
            animateDismiss(using: transitionContext)
        }
    }

    // MARK: Present

    private func animatePresent(using ctx: UIViewControllerContextTransitioning) {
        guard
            let toVC = ctx.viewController(forKey: .to),
            let toView = ctx.view(forKey: .to)
        else {
            ctx.completeTransition(false)
            return
        }

        let container = ctx.containerView
        let finalFrame = ctx.finalFrame(for: toVC)

        // Place destination view at its final layout immediately so the
        // WebView / subviews don't need to re-layout mid-animation.
        toView.frame = finalFrame
        toView.layoutIfNeeded()

        // Use a mask to reveal the destination view from the cell rect.
        // toView stays alpha = 1 the whole time — mask alone controls visibility.
        let maskView = UIView(frame: originFrame)
        maskView.backgroundColor = .black
        maskView.layer.cornerRadius = originCornerRadius
        maskView.layer.cornerCurve = .continuous
        toView.mask = maskView
        container.addSubview(toView)

        // Opaque background that fills the expanding rect so the home screen
        // underneath is gradually hidden.
        let bgView = UIView(frame: originFrame)
        bgView.backgroundColor = toView.backgroundColor ?? .systemBackground
        bgView.layer.cornerRadius = originCornerRadius
        bgView.layer.cornerCurve = .continuous
        bgView.clipsToBounds = true
        container.insertSubview(bgView, belowSubview: toView)

        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: springDamping,
            initialSpringVelocity: 0,
            options: [.curveEaseInOut]
        ) {
            maskView.frame = finalFrame
            maskView.layer.cornerRadius = 0
            bgView.frame = finalFrame
            bgView.layer.cornerRadius = 0
        } completion: { finished in
            toView.mask = nil
            bgView.removeFromSuperview()
            ctx.completeTransition(!ctx.transitionWasCancelled)
        }
    }

    // MARK: Dismiss

    private func animateDismiss(using ctx: UIViewControllerContextTransitioning) {
        guard
            let fromView = ctx.view(forKey: .from)
        else {
            ctx.completeTransition(false)
            return
        }

        let container = ctx.containerView

        // Ensure the "to" view (home) is behind
        if let toView = ctx.view(forKey: .to) {
            container.insertSubview(toView, belowSubview: fromView)
        }

        let startFrame = fromView.frame

        // Opaque background behind the shrinking mask so the home screen
        // is revealed progressively, not through a fading workspace.
        let bgView = UIView(frame: startFrame)
        bgView.backgroundColor = fromView.backgroundColor ?? .systemBackground
        bgView.layer.cornerRadius = 0
        bgView.layer.cornerCurve = .continuous
        bgView.clipsToBounds = true
        container.insertSubview(bgView, belowSubview: fromView)

        let maskView = UIView(frame: startFrame)
        maskView.backgroundColor = .black
        maskView.layer.cornerRadius = 0
        maskView.layer.cornerCurve = .continuous
        fromView.mask = maskView

        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: springDamping,
            initialSpringVelocity: 0,
            options: [.curveEaseInOut]
        ) {
            maskView.frame = self.originFrame
            maskView.layer.cornerRadius = self.originCornerRadius
            bgView.frame = self.originFrame
            bgView.layer.cornerRadius = self.originCornerRadius
            fromView.alpha = 0
            bgView.alpha = 0
        } completion: { finished in
            fromView.mask = nil
            bgView.removeFromSuperview()
            if ctx.transitionWasCancelled {
                fromView.alpha = 1
            } else {
                fromView.removeFromSuperview()
            }
            ctx.completeTransition(!ctx.transitionWasCancelled)
        }
    }
}

// MARK: - Interactive Dismiss Controller

final class ProjectDismissInteractionController: UIPercentDrivenInteractiveTransition {

    private(set) var isInteractive = false
    private weak var viewController: UIViewController?
    private let edgePanGesture: UIScreenEdgePanGestureRecognizer

    var isGestureEnabled: Bool {
        get { edgePanGesture.isEnabled }
        set { edgePanGesture.isEnabled = newValue }
    }

    init(viewController: UIViewController) {
        self.viewController = viewController
        edgePanGesture = UIScreenEdgePanGestureRecognizer()
        edgePanGesture.edges = .left
        super.init()

        edgePanGesture.addTarget(self, action: #selector(handleEdgePan(_:)))
        viewController.view.addGestureRecognizer(edgePanGesture)
    }

    @objc
    private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view)
        let screenWidth = view.bounds.width
        let progress = min(max(translation.x / screenWidth, 0), 1)

        switch gesture.state {
        case .began:
            isInteractive = true
            viewController?.dismiss(animated: true)
        case .changed:
            update(progress)
        case .ended, .cancelled:
            isInteractive = false
            let velocity = gesture.velocity(in: view).x
            // Complete if dragged past 35% or has strong velocity
            if progress > 0.35 || velocity > 800 {
                finish()
            } else {
                cancel()
            }
        default:
            isInteractive = false
            cancel()
        }
    }
}
