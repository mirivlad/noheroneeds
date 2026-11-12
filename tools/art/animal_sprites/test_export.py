"""The batched reducer must preserve the established RO pipeline pixel for pixel."""
import unittest
import numpy as np
from PIL import Image
from export import reduce_frame,reduce


class ReductionTest(unittest.TestCase):
    def test_matches_ro_including_alpha_thresholds_and_colour_ties(self):
        rng = np.random.default_rng(431)
        for scale in [2,4]:
            for seed in range(12):
                rgba = rng.integers(0,5,(28*scale,33*scale,4),dtype=np.uint8)*51
                rgba[...,3] = rng.choice([0,127,128,255],rgba.shape[:2])
                image = Image.fromarray(rgba)
                np.testing.assert_array_equal(reduce_frame(image,scale),reduce(image,scale))
        for alpha in [0,255]:
            image = Image.new('RGBA',(16,16),(255,255,255,alpha))
            np.testing.assert_array_equal(reduce_frame(image,4),reduce(image,4))


if __name__=='__main__': unittest.main()
