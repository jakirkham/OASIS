"""Extract neural activity from a fluorescence trace using OASIS,
an active set method for sparse nonnegative deconvolution
Created on Mon Apr 4 18:21:13 2016
@author: Johannes Friedrich
"""

import numpy as np
cimport numpy as np
from libc.math cimport sqrt, log, exp
from scipy.optimize import fminbound, minimize
from cpython cimport bool

ctypedef np.float_t DOUBLE


def oasisAR1(np.ndarray[DOUBLE, ndim=1] y, DOUBLE g, DOUBLE lam=0, DOUBLE s_min=0):
    """ Infer the most likely discretized spike train underlying an AR(1) fluorescence trace

    Solves the sparse non-negative deconvolution problem
    min 1/2|c-y|^2 + lam |s|_1 subject to s_t = c_t-g c_{t-1} >=s_min or =0

    Parameters
    ----------
    y : array of float
        One dimensional array containing the fluorescence intensities with
        one entry per time-bin.
    g : float
        Parameter of the AR(1) process that models the fluorescence impulse response.
    lam : float, optional, default 0
        Sparsity penalty parameter lambda.
    s_min : float, optional, default 0
        Minimal non-zero activity within each bin (minimal 'spike size').

    Returns
    -------
    c : array of float
        The inferred denoised fluorescence signal at each time-bin.
    s : array of float
        Discretized deconvolved neural activity (spikes)

    References
    ----------
    * Friedrich J and Paninski L, NIPS 2016
    """

    cdef:
        Py_ssize_t c, i, f, l
        unsigned int len_active_set
        DOUBLE v, w
        np.ndarray[DOUBLE, ndim = 1] solution

    len_active_set = len(y)
    solution = np.empty(len_active_set)
    # [value, weight, start time, length] of pool
    active_set = [[y[i] - lam * (1 - g), 1, i, 1] for i in range(len_active_set)]
    active_set[-1] = [y[-1] - lam, 1, len_active_set - 1, 1]  # |s|_1 instead |c|_1
    c = 0
    while c < len_active_set - 1:
        while c < len_active_set - 1 and \
            (active_set[c][0] / active_set[c][1] * g**active_set[c][3] + s_min <=
             active_set[c + 1][0] / active_set[c + 1][1]):
            c += 1
        if c == len_active_set - 1:
            break
        # merge two pools
        active_set[c][0] += active_set[c + 1][0] * g**active_set[c][3]
        active_set[c][1] += active_set[c + 1][1] * g**(2 * active_set[c][3])
        active_set[c][3] += active_set[c + 1][3]
        active_set.pop(c + 1)
        len_active_set -= 1
        while (c > 0 and  # backtrack until violations fixed
               (active_set[c - 1][0] / active_set[c - 1][1] * g**active_set[c - 1][3] + s_min >
                active_set[c][0] / active_set[c][1])):
            c -= 1
            # merge two pools
            active_set[c][0] += active_set[c + 1][0] * g**active_set[c][3]
            active_set[c][1] += active_set[c + 1][1] * g**(2 * active_set[c][3])
            active_set[c][3] += active_set[c + 1][3]
            active_set.pop(c + 1)
            len_active_set -= 1
    # construct solution
    for v, w, f, l in active_set:
        solution[f:f + l] = max(v, 0) / w * g**np.arange(l)
    return solution, np.append(0, solution[1:] - g * solution[:-1])


def constrained_oasisAR1(np.ndarray[DOUBLE, ndim=1] y, DOUBLE g, DOUBLE sn, bool optimize_b=False, int optimize_g=0, int decimate=1, int max_iter=5):
    """ Infer the most likely discretized spike train underlying an AR(1) fluorescence trace

    Solves the noise constrained sparse non-negative deconvolution problem
    min |s|_1 subject to |c-y|^2 = sn^2 T and s_t = c_t-g c_{t-1} >= 0

    Parameters
    ----------
    y : array of float
        One dimensional array containing the fluorescence intensities (with baseline
        already subtracted, if known, see optimize_b) with one entry per time-bin.
    g : float
        Parameter of the AR(1) process that models the fluorescence impulse response.
    sn : float
        Standard deviation of the noise distribution.
    optimize_b : bool, optional, default False
        Optimize baseline if True else it is set to 0, see y.
    optimize_g : int, optional, default 0
        Number of large, isolated events to consider for optimizing g.
        No optimization if optimize_g=0.
    decimate : int, optional, default 1
        Decimation factor for estimating hyper-parameters faster on decimated data.
    max_iter : int, optional, default 5
        Maximal number of iterations.

    Returns
    -------
    c : array of float
        The inferred denoised fluorescence signal at each time-bin.
    s : array of float
        Discretized deconvolved neural activity (spikes).
    b : float
        Fluorescence baseline value.
    g : float
        Parameter of the AR(1) process that models the fluorescence impulse response.
    lam : float
        Sparsity penalty parameter lambda of dual problem.

    References
    ----------
    * Friedrich J and Paninski L, NIPS 2016
    """

    cdef:
        Py_ssize_t c, i, f, l
        unsigned int len_active_set, ma, count, T
        DOUBLE thresh, v, w, RSS, aa, bb, cc, lam, dlam, b, db, dphi
        bool g_converged
        np.ndarray[DOUBLE, ndim = 1] solution, res, tmp, fluor
        np.ndarray[long, ndim = 1] ff, ll

    T = len(y)
    thresh = sn * sn * T
    if decimate > 1:  # parameter changes due to downsampling
        fluor = y.copy()
        y = y.reshape(-1, decimate).mean(1)
        g = g**decimate
        thresh = thresh / decimate / decimate
        T = len(y)
    len_active_set = T
    solution = np.empty(len_active_set)
    # [value, weight, start time, length] of pool
    active_set = [[y[i], 1, i, 1] for i in range(len_active_set)]

    def oasis(active_set, g, solution):
        solution = np.empty(active_set[-1][2] + active_set[-1][3])
        len_active_set = len(active_set)
        c = 0
        while c < len_active_set - 1:
            while c < len_active_set - 1 and \
                (active_set[c][0] * active_set[c + 1][1] * g**active_set[c][3] <=
                 active_set[c][1] * active_set[c + 1][0]):
                c += 1
            if c == len_active_set - 1:
                break
            # merge two pools
            active_set[c][0] += active_set[c + 1][0] * g**active_set[c][3]
            active_set[c][1] += active_set[c + 1][1] * g**(2 * active_set[c][3])
            active_set[c][3] += active_set[c + 1][3]
            active_set.pop(c + 1)
            len_active_set -= 1
            while (c > 0 and  # backtrack until violations fixed
                   (active_set[c - 1][0] * active_set[c][1] * g**active_set[c - 1][3] >
                    active_set[c - 1][1] * active_set[c][0])):
                c -= 1
                # merge two pools
                active_set[c][0] += active_set[c + 1][0] * g**active_set[c][3]
                active_set[c][1] += active_set[c + 1][1] * g**(2 * active_set[c][3])
                active_set[c][3] += active_set[c + 1][3]
                active_set.pop(c + 1)
                len_active_set -= 1
        # construct solution
        for v, w, f, l in active_set:
            solution[f:f + l] = v / w * np.exp(log(g) * np.arange(l))
        solution[solution < 0] = 0
        return solution, active_set

    if not optimize_b:  # don't optimize b nor g, just the dual variable lambda
        solution, active_set = oasis(active_set, g, solution)
        tmp = np.empty(len(solution))
        res = y - solution
        RSS = (res).dot(res)
        lam = 0
        # until noise constraint is tight or spike train is empty
        while RSS < thresh * (1 - 1e-4) and sum(solution) > 1e-9:
            # calc RSS
            res = y - solution
            RSS = res.dot(res)
            # update lam
            for i, (v, w, f, l) in enumerate(active_set):
                if i == len(active_set) - 1:  # for |s|_1 instead |c|_1 sparsity
                    tmp[f:f + l] = 1 / w * np.exp(log(g) * np.arange(l))
                else:
                    tmp[f:f + l] = (1 - g**l) / w * np.exp(log(g) * np.arange(l))
            aa = tmp.dot(tmp)
            bb = res.dot(tmp)
            cc = RSS - thresh
            dlam = (-bb + sqrt(bb * bb - aa * cc)) / aa
            lam += dlam
            for a in active_set:     # perform shift
                a[0] -= dlam * (1 - g**a[3])
            solution, active_set = oasis(active_set, g, solution)

    else:  # optimize b and dependend on optimize_g g too
        b = np.percentile(y, 15)  # initial estimate of baseline
        for a in active_set:     # subtract baseline
            a[0] -= b
        solution, active_set = oasis(active_set, g, solution)
        # update b and lam
        db = np.mean(y - solution) - b
        b += db
        lam = -db / (1 - g)
        # correct last pool
        active_set[-1][0] -= lam * g**active_set[-1][3]  # |s|_1 instead |c|_1
        v, w, f, l = active_set[-1]
        solution[f:f + l] = max(0, v) / w * np.exp(log(g) * np.arange(l))
        # calc RSS
        res = y - b - solution
        RSS = res.dot(res)
        tmp = np.empty(len(solution))
        g_converged = False
        count = 0
        # until noise constraint is tight or spike train is empty or max_iter reached
        while (RSS < thresh * (1 - 1e-4) or RSS > thresh * (1 + 1e-4)) and sum(solution) > 1e-9 and count < max_iter:
            count += 1
            # update lam and b
            # calc total shift dphi due to contribution of baseline and lambda
            for i, (v, w, f, l) in enumerate(active_set):
                if i == len(active_set) - 1:  # for |s|_1 instead |c|_1 sparsity
                    tmp[f:f + l] = 1 / w * np.exp(log(g) * np.arange(l))
                else:
                    tmp[f:f + l] = (1 - g**l) / w * np.exp(log(g) * np.arange(l))
            tmp -= 1. / T / (1 - g) * np.sum([(1 - g**l)**2 / w for (_, w, _, l) in active_set])
            aa = tmp.dot(tmp)
            bb = res.dot(tmp)
            cc = RSS - thresh
            dphi = (-bb + sqrt(bb * bb - aa * cc)) / aa
            b += dphi * (1 - g)
            for a in active_set:     # perform shift
                a[0] -= dphi * (1 - g**a[3])
            solution, active_set = oasis(active_set, g, solution)
            # update b and lam
            db = np.mean(y - solution) - b
            b += db
            dlam = -db / (1 - g)
            lam += dlam
            # correct last pool
            active_set[-1][0] -= dlam * g**active_set[-1][3]  # |s|_1 instead |c|_1
            v, w, f, l = active_set[-1]
            solution[f:f + l] = max(0, v) / w * np.exp(log(g) * np.arange(l))

            # update g and b
            if optimize_g and count < max_iter - 1 and (not g_converged):
                ma = max([a[3] for a in active_set])
                idx = np.argsort([a[0] for a in active_set])

                def bar(y, opt, a_s):
                    b, g = opt
                    qq = np.exp(log(g) * np.arange(ma))

                    def foo(y, t_hat, len_set, q, b, g, lam=lam):
                        yy = y[t_hat:t_hat + len_set] - b
                        if t_hat + len_set == T:  # |s|_1 instead |c|_1
                            tmp = ((q.dot(yy) - lam) * (1 - g * g)
                                   / (1 - g**(2 * len_set))) * q - yy
                        else:
                            tmp = ((q.dot(yy) - lam * (1 - g**len_set)) * (1 - g * g)
                                   / (1 - g**(2 * len_set))) * q - yy
                        return tmp.dot(tmp)
                    return sum([foo(y, a_s[i][2], a_s[i][3], qq[:a_s[i][3]], b, g) for i in idx[-optimize_g:]])

                def baz(y, active_set):
                    return minimize(lambda x: bar(y, x, active_set), (b, g), bounds=((0, None), (0, 1)), method='L-BFGS-B',
                                    options={'gtol': 1e-04, 'maxiter': 3, 'ftol': 1e-05})
                result = baz(y, active_set)
                if abs(result['x'][1] - g) < 1e-3:
                    g_converged = True
                b, g = result['x']
                qq = np.exp(log(g) * np.arange(ma))
                for a in active_set:
                    q = qq[:a[3]]
                    a[0] = q.dot(y[a[2]:a[2] + a[3]]) - (b / (1 - g) + lam) * (1 - g**a[3])
                    a[1] = q.dot(q)
                active_set[-1][0] -= lam * g**active_set[-1][3]  # |s|_1 instead |c|_1
                solution, active_set = oasis(active_set, g, solution)
                # update b and lam
                db = np.mean(y - solution) - b
                b += db
                dlam = -db / (1 - g)
                lam += dlam
                # correct last pool
                active_set[-1][0] -= dlam * g**active_set[-1][3]  # |s|_1 instead |c|_1
                v, w, f, l = active_set[-1]
                solution[f:f + l] = max(0, v) / w * np.exp(log(g) * np.arange(l))

            # calc RSS
            res = y - solution - b
            RSS = res.dot(res)

    if decimate > 1:  # deal with full data
        lam = lam * (1 - g)
        g = g**(1. / decimate)
        lam = lam / (1 - g)
        thresh = thresh * decimate * decimate
        T = len(fluor)
        # warm-start active set
        ff = np.hstack([a[2] * decimate + np.arange(-decimate, 3 * decimate / 2)
                        for a in active_set])  # this window size seems necessary and sufficient
        ff = np.unique(ff[(ff >= 0) * (ff < T)])
        ll = np.append(ff[1:] - ff[:-1], T - ff[-1])
        active_set = map(list, zip([0.] * len(ll), [0.] * len(ll), list(ff), list(ll)))
        ma = max([a[3] for a in active_set])
        qq = np.exp(log(g) * np.arange(ma))
        for a in active_set:
            q = qq[:a[3]]
            a[0] = q.dot(fluor[a[2]:a[2] + a[3]]) - (b / (1 - g) + lam) * (1 - g**a[3])
            a[1] = q.dot(q)
        active_set[-1][0] -= lam * g**active_set[-1][3]  # |s|_1 instead |c|_1
        solution = np.empty(T)

        solution, active_set = oasis(active_set, g, solution)

    return solution, np.append(0, solution[1:] - g * solution[:-1]), b, g, lam


# TODO: initial fluorescence
def oasisAR2(np.ndarray[DOUBLE, ndim=1] y, DOUBLE g1, DOUBLE g2,
             DOUBLE lam=0, DOUBLE s_min=0, int T_over_ISI=1, bool jitter=False):
    """ Infer the most likely discretized spike train underlying an AR(2) fluorescence trace

    Solves the sparse non-negative deconvolution problem
    min 1/2|c-y|^2 + lam |s|_1 subject to s_t = c_t-g1 c_{t-1}-g2 c_{t-2} >=s_min or =0

    Parameters
    ----------
    y : array of float
        One dimensional array containing the fluorescence intensities with
        one entry per time-bin.
    g1 : float
        First parameter of the AR(2) process that models the fluorescence impulse response.
    g2 : float
        Second parameter of the AR(2) process that models the fluorescence impulse response.
    lam : float, optional, default 0
        Sparsity penalty parameter lambda.
    s_min : float, optional, default 0
        Minimal non-zero activity within each bin (minimal 'spike size').
    T_over_ISI : int, optional, default 1
        Ratio of recording duration T and maximal inter-spike-interval ISI
    jitter : bool, optional, default False
        Perform correction step by jittering spike times to minimize RSS.
        Helps to avoid delayed spike detection.

    Returns
    -------
    c : array of float
        The inferred denoised fluorescence signal at each time-bin.
    s : array of float
        Discretized deconvolved neural activity (spikes).

    References
    ----------
    * Friedrich J and Paninski L, NIPS 2016
    """

    cdef:
        Py_ssize_t c, i, j, l, f
        unsigned int len_active_set, len_g
        DOUBLE d, r, v, last, tmp, ltmp, RSSold, RSSnew
        np.ndarray[DOUBLE, ndim = 1] _y, solution, g11, g12, g11g11, g11g12, tmparray
    _y = y - lam * (1 - g1 - g2)
    _y[-2] = y[-2] - lam * (1 - g1)
    _y[-1] = y[-1] - lam

    len_active_set = len(_y)
    solution = np.empty(len_active_set)
    # [first value, last value, start time, length] of pool
    active_set = [[_y[i], _y[i], i, 1] for i in xrange(len_active_set)]
    # precompute
    len_g = len_active_set / T_over_ISI
    d = (g1 + sqrt(g1 * g1 + 4 * g2)) / 2
    r = (g1 - sqrt(g1 * g1 + 4 * g2)) / 2
    g11 = (np.exp(log(d) * np.arange(1, len_g + 1)) -
           np.exp(log(r) * np.arange(1, len_g + 1))) / (d - r)
    g12 = np.append(0, g2 * g11[:-1])
    g11g11 = np.cumsum(g11 * g11)
    g11g12 = np.cumsum(g11 * g12)

    c = 1
    while c < len_active_set - 1:
        while (c < len_active_set - 1 and  # predict
               (g11[active_set[c][3]] * active_set[c][0]
                + g12[active_set[c][3]] * active_set[c - 1][1])
               <= active_set[c + 1][0] - s_min):
            c += 1
        if c == len_active_set - 1:
            break
        # merge
        active_set[c][3] += active_set[c + 1][3]
        l = active_set[c][3] - 1
        active_set[c][0] = (g11[:l + 1].dot(
            _y[active_set[c][2]:active_set[c][2] + active_set[c][3]])
            - g11g12[l] * active_set[c - 1][1]) / g11g11[l]
        active_set[c][1] = (g11[l] * active_set[c][0] + g12[l] * active_set[c - 1][1])
        active_set.pop(c + 1)
        len_active_set -= 1

        while (c > 1 and  # backtrack until violations fixed
               (g11[active_set[c - 1][3]] * active_set[c - 1][0]
                + g12[active_set[c - 1][3]] * active_set[c - 2][1])
                > active_set[c][0] - s_min):
            c -= 1
            # merge
            active_set[c][3] += active_set[c + 1][3]
            l = active_set[c][3] - 1
            active_set[c][0] = (g11[:l + 1].dot(
                _y[active_set[c][2]:active_set[c][2] + active_set[c][3]])
                - g11g12[l] * active_set[c - 1][1]) / g11g11[l]
            active_set[c][1] = (g11[l] * active_set[c][0] + g12[l] * active_set[c - 1][1])
            active_set.pop(c + 1)
            len_active_set -= 1

    # jitter
    a_s = active_set
    if jitter:
        for c in xrange(1, len(a_s) - 1):
            tmparray = a_s[c][0] * g11[:a_s[c][3]] + a_s[c - 1][1] * g12[:a_s[c][3]]
            tmparray -= _y[a_s[c][2]:a_s[c][2] + a_s[c][3]]
            RSSold = tmparray.dot(tmparray)
            tmparray = a_s[c + 1][0] * g11[:a_s[c + 1][3]] + a_s[c][1] * g12[:a_s[c + 1][3]]
            tmparray -= _y[a_s[c + 1][2]:a_s[c + 1][2] + a_s[c + 1][3]]
            RSSold += tmparray.dot(tmparray)
            j = 0

            for i in range(-2, 0) + [1]:
                if a_s[c][3] + i > 0 and a_s[c + 1][3] - i > 0 and a_s[c + 1][2] + a_s[c + 1][3] - i <= len(_y):
                    l = a_s[c][3] + i
                    tmp = (g11[:l].dot(_y[a_s[c][2]:a_s[c][2] + l])
                           - g11g12[l - 1] * a_s[c - 1][1]) / g11g11[l - 1]  # first value of pool prev to jittered spike
                    # new values of pool prev to jittered spike
                    tmparray = tmp * g11[:l] + a_s[c - 1][1] * g12[:l]
                    ltmp = tmparray[-1]  # last value of pool prev to jittered spike
                    tmparray -= _y[a_s[c][2]:a_s[c][2] + l]
                    RSSnew = tmparray.dot(tmparray)

                    l = a_s[c + 1][3] - i
                    tmp = (g11[:l].dot(_y[a_s[c + 1][2] + i:a_s[c + 1][2] + a_s[c + 1][3]])
                           - g11g12[l - 1] * ltmp) / g11g11[l - 1]
                    # new values of pool after jittered spike
                    tmparray = tmp * g11[:l] + ltmp * g12[:l]
                    tmparray -= _y[a_s[c + 1][2] + i:a_s[c + 1][2] + a_s[c + 1][3]]
                    RSSnew += tmparray.dot(tmparray)

                    if RSSnew < RSSold:
                        RSSold = RSSnew
                        j = i

            if j != 0:
                a_s[c][3] += j
                l = a_s[c][3] - 1
                a_s[c][0] = (g11[:l + 1].dot(_y[a_s[c][2]:a_s[c][2] + a_s[c][3]])
                             - g11g12[l] * a_s[c - 1][1]) / g11g11[l]  # first value of pool prev to jittered spike
                a_s[c][1] = a_s[c][0] * g11[l] + a_s[c - 1][1] * g12[l]  # last value of prev pool

                a_s[c + 1][2] += j
                a_s[c + 1][3] -= j
                l = a_s[c + 1][3] - 1
                a_s[c + 1][0] = (g11[:l + 1].dot(_y[a_s[c + 1][2]:a_s[c + 1][2] + a_s[c + 1][3]])
                                 - g11g12[l] * a_s[c][1]) / g11g11[l]  # first value of pool after jittered spike
                a_s[c + 1][1] = a_s[c + 1][0] * g11[l] + a_s[c][1] * g12[l]  # last

    # construct solution
    for c, (v, last, f, l) in enumerate(a_s):
        solution[f] = v
        if l > 1:
            solution[f + 1] = (g1 * solution[f] + g2 * a_s[c - 1][1])
            for i in xrange(2, l):
                solution[f + i] = (g1 * solution[f + i - 1] + g2 * solution[f + i - 2])
    solution[solution < 0] = 0
    return solution, np.append([0, 0, 0], solution[3:] - g1 * solution[2:-1] - g2 * solution[1:-2])


# TODO: |s|_1 instead |c|_1, initial fluorescence, optimize b&g
def constrained_oasisAR2(np.ndarray[DOUBLE, ndim=1] y, DOUBLE g1, DOUBLE g2,
                         DOUBLE sn, int T_over_ISI=1):
    """ Infer the most likely discretized spike train underlying an AR(2) fluorescence trace

    Solves the noise constrained sparse non-negative deconvolution problem
    min |s|_1 subject to |c-y|^2 = sn^2 T and s_t = c_t-g1 c_{t-1}-g2 c_{t-2} >= 0

    Parameters
    ----------
    y : array of float
        One dimensional array containing the fluorescence intensities (with baseline
        already subtracted) with one entry per time-bin.
    g1 : float
        First parameter of the AR(2) process that models the fluorescence impulse response.
    g2 : float
        Second parameter of the AR(2) process that models the fluorescence impulse response.
    sn : float
        Standard deviation of the noise distribution.
    T_over_ISI : int, optional, default 1
        Ratio of recording duration T and maximal inter-spike-interval ISI

    Returns
    -------
    c : array of float
        The inferred denoised fluorescence signal at each time-bin.
    s : array of float
        Discretized deconvolved neural activity (spikes).

    References
    ----------
    * Friedrich J and Paninski L, NIPS 2016
    """

    cdef:
        Py_ssize_t c, i, l, f
        unsigned int len_active_set, len_g
        DOUBLE thresh, d, r, v, last, w1, w2, lam, dlam, RSS, aa, bb, cc, ll
        np.ndarray[DOUBLE, ndim = 1] solution, res, g11, g12, g11g11, g11g12, tmp

    len_active_set = len(y)
    thresh = sn * sn * len_active_set
    solution = np.empty(len_active_set)
    # [value, weight, start time, length] of pool
    active_set = [[y[i], y[i], i, 1] for i in xrange(len_active_set)]
    # precompute
    len_g = len_active_set / T_over_ISI
    d = (g1 + sqrt(g1 * g1 + 4 * g2)) / 2
    r = (g1 - sqrt(g1 * g1 + 4 * g2)) / 2
    g11 = (np.exp(log(d) * np.arange(1, len_g + 1)) -
           np.exp(log(r) * np.arange(1, len_g + 1))) / (d - r)
    g12 = np.append(0, g2 * g11[:-1])
    g11g11 = np.cumsum(g11 * g11)
    g11g12 = np.cumsum(g11 * g12)

    def oasis(y, active_set, solution, g11, g12, g11g11, g11g12):
        len_active_set = len(active_set)
        c = 1
        while c < len_active_set - 1:
            while (c < len_active_set - 1 and  # backtrack until violations fixed
                   (g11[active_set[c][3]] * active_set[c][0]
                    + g12[active_set[c][3]] * active_set[c - 1][1])
                   <= active_set[c + 1][0]):
                c += 1
            if c == len_active_set - 1:
                break
            # merge
            active_set[c][3] += active_set[c + 1][3]
            l = active_set[c][3] - 1
            active_set[c][0] = (g11[:l + 1].dot(
                y[active_set[c][2]:active_set[c][2] + active_set[c][3]])
                - g11g12[l] * active_set[c - 1][1]) / g11g11[l]
            active_set[c][1] = (g11[l] * active_set[c][0] + g12[l] * active_set[c - 1][1])
            active_set.pop(c + 1)
            len_active_set -= 1

            while (c > 1 and  # backtrack until violations fixed
                   (g11[active_set[c - 1][3]] * active_set[c - 1][0]
                    + g12[active_set[c - 1][3]] * active_set[c - 2][1])
                    > active_set[c][0]):
                c -= 1
                # merge
                active_set[c][3] += active_set[c + 1][3]
                l = active_set[c][3] - 1
                active_set[c][0] = (g11[:l + 1].dot(
                    y[active_set[c][2]:active_set[c][2] + active_set[c][3]])
                    - g11g12[l] * active_set[c - 1][1]) / g11g11[l]
                active_set[c][1] = (g11[l] * active_set[c][0] + g12[l] * active_set[c - 1][1])
                active_set.pop(c + 1)
                len_active_set -= 1

        # construct solution
        for c, (v, last, f, l) in enumerate(active_set):
            solution[f] = v
            if l > 1:
                solution[f + 1] = (g1 * solution[f] + g2 * active_set[c - 1][1])
                for i in xrange(2, l):
                    solution[f + i] = (g1 * solution[f + i - 1] + g2 * solution[f + i - 2])
        solution[solution < 0] = 0
        return solution, active_set

    solution, active_set = oasis(y, active_set, solution, g11, g12, g11g11, g11g12)
    tmp = np.ones(len(solution))
    lam = 0
    res = y - solution
    RSS = (res).dot(res)
    # until noise constraint is tight or spike train is empty
    while (RSS < thresh * (1 - 1e-4) and sum(solution) > 1e-9):
        # calc RSS
        res = y - solution
        RSS = res.dot(res)
        # update lam
        for i, a in enumerate(active_set):
            l = a[3] - 1
            tmp[a[2]] = (g11[:l + 1].sum() - g11g12[l] * tmp[a[2] - 1]) / g11g11[l]
            for k in range(a[2] + 1, a[2] + a[3]):
                tmp[k] = g1 * tmp[k - 1] + g2 * tmp[k - 2]
        aa = tmp.dot(tmp)
        bb = res.dot(tmp)
        cc = RSS - thresh
        dlam = (-bb + sqrt(bb * bb - aa * cc)) / aa
        lam += dlam
        # perform shift by dlam
        for i, a in enumerate(active_set):
            if i == 0:
                a[0] -= dlam
                a[1] = a[0]
                ll = -dlam  # amount of change in last element of pool
            else:
                l = a[3] - 1
                a[0] -= (dlam * g11[:l + 1].sum() + g11g12[l] * ll) / g11g11[l]
                ll = -a[1]
                a[1] = g11[l] * a[0] + g12[l] * active_set[i - 1][1]
                ll += a[1]
        solution, active_set = oasis(y - lam, active_set, solution,
                                     g11, g12, g11g11, g11g12)

    return solution, np.append([0, 0, 0], solution[3:] - g1 * solution[2:-1] - g2 * solution[1:-2])