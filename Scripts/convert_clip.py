#!/usr/bin/env python3
"""Convert OpenAI CLIP ViT-B/32 into two Core ML programs for Stillroom.

The checkpoint is MIT licensed (Copyright 2021 OpenAI). This file only
converts a checkpoint you already downloaded. It does not contact the
network. `Scripts/fetch-clip.sh` is what downloads and checks the file.

The image program takes an RGB picture already scaled to 0...1 (Core ML
applies 1/255) and returns one L2-normalized 512-vector named `embedding`.
CLIP's mean and standard deviation are inside the program.

The text program takes int32 token ids shaped [1, 77] and returns the full
token sequence named `sequence`, shaped [1, 77, 512], after the final layer
norm and the text projection. It does not gather the end-of-text row.
Tracing that gather would freeze the example index. Stillroom picks the
end-of-text row itself and normalizes it.

This converter was not executed in the environment that added it. It needs
PyTorch, the `clip` package, and coremltools. Compiling the packages into
`.mlmodelc` needs Xcode on a Mac (`xcrun coremlcompiler`).
"""

from __future__ import annotations

import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from torch import nn

import clip


IMAGE_SIDE = 224
CONTEXT = 77
MEAN = (0.48145466, 0.4578275, 0.40821073)
STD = (0.26862954, 0.26130258, 0.27577711)


class ImageTower(nn.Module):
    def __init__(self, visual: nn.Module) -> None:
        super().__init__()
        self.visual = visual
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        # image is NCHW float32 in 0...1. Core ML has already applied scale 1/255.
        x = (image - self.mean) / self.std
        features = self.visual(x)
        norm = features.norm(dim=-1, keepdim=True).clamp(min=1e-12)
        return features / norm


class TextTower(nn.Module):
    def __init__(self, model: nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(self, tokens: torch.Tensor) -> torch.Tensor:
        # Keep every token. Gathering argmax(tokens) here is not safe to trace.
        model = self.model
        cast = model.token_embedding.weight.dtype
        x = model.token_embedding(tokens.long()).to(cast)
        x = x + model.positional_embedding.to(cast)
        x = x.permute(1, 0, 2)
        x = model.transformer(x)
        x = x.permute(1, 0, 2)
        x = model.ln_final(x).to(cast)
        return x @ model.text_projection


def convert(checkpoint: Path, output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    loaded, _ = clip.load(str(checkpoint), device="cpu", jit=False)
    loaded = loaded.float().eval()
    for parameter in loaded.parameters():
        parameter.requires_grad_(False)

    image_tower = ImageTower(loaded.visual).eval()
    text_tower = TextTower(loaded).eval()
    example_image = torch.rand(1, 3, IMAGE_SIDE, IMAGE_SIDE)
    example_tokens = torch.zeros(1, CONTEXT, dtype=torch.int32)
    example_tokens[0, 0] = 49406  # start of text in the full CLIP vocabulary
    example_tokens[0, 1] = 49407  # end of text

    with torch.no_grad():
        image_traced = torch.jit.trace(image_tower, example_image)
        text_traced = torch.jit.trace(text_tower, example_tokens)

    image_model = ct.convert(
        image_traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, IMAGE_SIDE, IMAGE_SIDE),
                color_layout=ct.colorlayout.RGB,
                scale=1.0 / 255.0,
                bias=[0.0, 0.0, 0.0],
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
    )
    text_model = ct.convert(
        text_traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
        inputs=[ct.TensorType(name="tokens", shape=(1, CONTEXT), dtype=np.int32)],
        outputs=[ct.TensorType(name="sequence")],
    )
    image_path = output_dir / "ImageEncoder.mlpackage"
    text_path = output_dir / "TextEncoder.mlpackage"
    image_model.save(str(image_path))
    text_model.save(str(text_path))
    print(f"Wrote {image_path}")
    print(f"Wrote {text_path}")
    print("Image input image RGB 224, scale 1/255. Output embedding [1, 512], L2-normalized.")
    print("Text input tokens int32 [1, 77]. Output sequence [1, 77, 512], not pooled.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    convert(args.checkpoint, args.output_dir)


if __name__ == "__main__":
    main()
