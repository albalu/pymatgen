# coding: utf-8

#from __future__ import division, unicode_literals

"""
Utilities for manipulating coordinates or list of coordinates, under periodic
boundary conditions or otherwise.
"""

from six.moves import zip

__author__ = "Will Richards"
__copyright__ = "Copyright 2011, The Materials Project"
__version__ = "1.0"
__maintainer__ = "Will Richards"
__email__ = "wmdrichards@gmail.com"
__date__ = "Nov 27, 2011"

import numpy as np

from libc.stdlib cimport malloc, free
from libc.math cimport round, abs, sqrt, acos, M_PI, cos, sin
cimport numpy as np
cimport cython

#create images, 2d array of all length 3 combinations of [-1,0,1]
r = np.arange(-1, 2, dtype=np.float_)
arange = r[:, None] * np.array([1, 0, 0])[None, :]
brange = r[:, None] * np.array([0, 1, 0])[None, :]
crange = r[:, None] * np.array([0, 0, 1])[None, :]
images_t = arange[:, None, None] + brange[None, :, None] + \
    crange[None, None, :]
images = images_t.reshape((27, 3))

cdef np.float_t[:, ::1] images_view = images

@cython.boundscheck(False)
@cython.wraparound(False)
cdef void dot_2d(np.float_t[:, ::1] a, np.float_t[:, ::1] b, np.float_t[:, ::1] o) nogil:
    cdef int i, j, k, I, J, K
    I = a.shape[0]
    J = b.shape[1]
    K = a.shape[1]

    for j in range(J):
        for i in range(I):
            o[i, j] = 0
        for k in range(K):
            for i in range(I):
                o[i, j] += a[i, k] * b[k, j]

@cython.boundscheck(False)
@cython.wraparound(False)
cdef void dot_2d_mod(np.float_t[:, ::1] a, np.float_t[:, ::1] b, np.float_t[:, ::1] o) nogil:
    cdef int i, j, k, I, J, K
    I = a.shape[0]
    J = b.shape[1]
    K = a.shape[1]

    for j in range(J):
        for i in range(I):
            o[i, j] = 0
        for k in range(K):
            for i in range(I):
                o[i, j] += a[i, k] % 1 * b[k, j]

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.initializedcheck(False)
def pbc_shortest_vectors(lattice, fcoords1, fcoords2, mask=None, return_d2=False):
    """
    Returns the shortest vectors between two lists of coordinates taking into
    account periodic boundary conditions and the lattice.

    Args:
        lattice: lattice to use
        fcoords1: First set of fractional coordinates. e.g., [0.5, 0.6, 0.7]
            or [[1.1, 1.2, 4.3], [0.5, 0.6, 0.7]]. Must be np.float_
        fcoords2: Second set of fractional coordinates.
        mask (int_ array): Mask of matches that are not allowed.
            i.e. if mask[1,2] == True, then subset[1] cannot be matched
            to superset[2]

    Returns:
        array of displacement vectors from fcoords1 to fcoords2
        first index is fcoords1 index, second is fcoords2 index
    """

    #ensure correct shape
    fcoords1, fcoords2 = np.atleast_2d(fcoords1, fcoords2)

    cdef np.float_t[:, ::1] lat = np.array(lattice._matrix, dtype=np.float_, copy=False, order='C')

    cdef int i, j, k, l, I, J, bestK

    I = len(fcoords1)
    J = len(fcoords2)

    cdef np.float_t[:, ::1] cart_f1 = <np.float_t[:I, :3]> malloc(3 * I * sizeof(np.float_t))
    cdef np.float_t[:, ::1] cart_f2 = <np.float_t[:J, :3]> malloc(3 * J * sizeof(np.float_t))
    cdef np.float_t[:, ::1] cart_im = <np.float_t[:27, :3]> malloc(81 * sizeof(np.float_t))

    cdef bint has_mask = mask is not None
    cdef np.int_t[:, :] m
    if has_mask:
        m = np.array(mask, dtype=np.int_, copy=False, order='C')

    dot_2d_mod(fcoords1, lat, cart_f1)
    dot_2d_mod(fcoords2, lat, cart_f2)
    dot_2d(images_view, lat, cart_im)

    vectors = np.empty((I, J, 3))
    d2 = np.empty((I, J))
    cdef np.float_t[:, :, ::1] vs = vectors
    cdef np.float_t[:, ::1] ds = d2
    cdef np.float_t best, d, inc_d, da, db, dc

    cdef np.float_t[::1] pre_im = <np.float_t[:3]> malloc(3 * sizeof(np.float_t))

    for i in range(I):
        for j in range(J):
            best = 1e100
            if has_mask and m[i, j]:
                ds[i, j] = 1e20
                for l in range(3):
                    vs[i, j, l] = 1e20
            else:
                for l in range(3):
                    pre_im[l] = cart_f2[j, l] - cart_f1[i, l]
                for k in range(27):
                    # compilers have a hard time unrolling this
                    da = pre_im[0] + cart_im[k, 0]
                    db = pre_im[1] + cart_im[k, 1]
                    dc = pre_im[2] + cart_im[k, 2]
                    d = da * da + db * db + dc * dc
                    if d < best:
                        best = d
                        bestk = k
                ds[i, j] = best
                for l in range(3):
                    vs[i, j, l] = pre_im[l] + cart_im[bestk, l]

    free(&cart_f1[0,0])
    free(&cart_f2[0,0])
    free(&cart_im[0,0])
    free(&pre_im[0])

    if return_d2:
        return vectors, d2
    else:
        return vectors

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.initializedcheck(False)
def is_coord_subset_pbc(subset, superset, atol, mask):
    """
    Tests if all fractional coords in subset are contained in superset.
    Allows specification of a mask determining pairs that are not
    allowed to match to each other

    Args:
        subset, superset: List of fractional coords

    Returns:
        True if all of subset is in superset.
    """

    cdef np.float_t[:, :] fc1 = subset
    cdef np.float_t[:, :] fc2 = superset
    cdef np.float_t[:] t = atol
    cdef np.int_t[:, :] m = np.array(mask, dtype=np.int_, copy=False, order='C')

    cdef int i, j, k, I, J
    cdef np.float_t d
    cdef bint ok = False

    I = fc1.shape[0]
    J = fc2.shape[0]

    for i in range(I):
        for j in range(J):
            if m[i, j]:
                continue
            ok = True
            for k in range(3):
                d = fc1[i, k] - fc2[j, k]
                if abs(d - round(d)) > t[k]:
                    ok = False
                    break
            if ok:
                break
        if not ok:
            break
    return bool(ok)

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.initializedcheck(False)
def det3x3(matrix):
    cdef np.float_t[:, :] m_f
    cdef np.long_t[:, :] m_l
    cdef np.float_t o_64 = 0
    cdef np.long_t o_l = 0

    if matrix.dtype == np.float_:
        m_f = matrix
        o_64 = m_f[0, 0] * m_f[1, 1] * m_f[2, 2] + m_f[1, 0] * m_f[2, 1] * m_f[0, 2] + m_f[2, 0] * m_f[0, 1] * m_f[1, 2] \
            - m_f[0, 2] * m_f[1, 1] * m_f[2, 0] - m_f[1, 2] * m_f[2, 1] * m_f[0, 0] - m_f[2, 2] * m_f[0, 1] * m_f[1, 0]
        return o_64
    if matrix.dtype == np.long:
        m_l = matrix
        o_l = m_l[0, 0] * m_l[1, 1] * m_l[2, 2] + m_l[1, 0] * m_l[2, 1] * m_l[0, 2] + m_l[2, 0] * m_l[0, 1] * m_l[1, 2] \
            - m_l[0, 2] * m_l[1, 1] * m_l[2, 0] - m_l[1, 2] * m_l[2, 1] * m_l[0, 0] - m_l[2, 2] * m_l[0, 1] * m_l[1, 0]
        return o_l